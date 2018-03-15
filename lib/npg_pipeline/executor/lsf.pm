package npg_pipeline::executor::lsf;

use Moose;
use MooseX::StrictConstructor;
use MooseX::AttributeCloner;
use namespace::autoclean;
use Sys::Filesystem::MountPoint qw(path_to_mount_point);
use File::Spec;
use Try::Tiny;
use List::MoreUtils qw(uniq);
use Readonly;
use English qw(-no_match_vars);

use npg_tracking::util::abs_path qw(abs_path network_abs_path);
use npg_pipeline::executor::lsf::job;

extends 'npg_tracking::illumina::runfolder';
with qw( 
         npg_pipeline::executor::lsf::options
         npg_pipeline::roles::accessor
         WTSI::DNAP::Utilities::Loggable
       );

our $VERSION = '0';

Readonly::Scalar my $VERTEX_LSF_JOB_IDS_ATTR_NAME => q[lsf_job_ids];
Readonly::Scalar my $LSF_JOB_IDS_DELIM            => q[-];
Readonly::Scalar my $SUSPENDED_START_FUNCTION     => q[pipeline_start];
Readonly::Scalar my $END_FUNCTION                 => q[pipeline_end];
Readonly::Scalar my $DEFAULT_MAX_TRIES            => 3;
Readonly::Scalar my $DEFAULT_MIN_SLEEP            => 1;
Readonly::Scalar my $DEFAULT_JOB_ID_FOR_NO_BSUB   => 50;

=head1 NAME

npg_pipeline::executor::lsf

=head1 SYNOPSIS

=head1 DESCRIPTION

Submission of function definition for execution to LSF.

=head1 SUBROUTINES/METHODS

=cut

##################################################################
################## Public attributes #############################
##################################################################

=head2 lsf_conf

=cut

has 'lsf_conf' => (
  isa        => 'HashRef',
  is         => 'ro',
  lazy_build => 1,
);
sub _build_lsf_conf {
  my $self = shift;
  return $self->read_config($self->conf_file_path('lsf.ini'));
}

=head2 function_graph

=cut

has 'function_graph' => (
  is       => 'ro',
  isa      => 'Graph::Directed',
  required => 1,
);

=head2 function_definitions

=cut

has 'function_definitions' => (
  is       => 'ro',
  isa      => 'HashRef',
  required => 1,
);

=head2 fs_resource

Returns the fs_resource for the runfolder path or,
if no_sf_resource attribute is true, an undefined
value.

=cut 

has 'fs_resource' => (
  is         => 'ro',
  isa        => 'Maybe[Str]',
  lazy_build => 1,
);
sub _build_fs_resource {
  my $self = @_;
  if (!$self->no_sf_resource()) {
    my $r = join '_', grep {$_}
                      File::Spec->splitdir(
                        network_abs_path
                        path_to_mount_point($self->runfolder_path()));
    return join q(),$r=~/\w+/xsmg;
  }
  return;
}

##################################################################
############## Public methods ####################################
##################################################################

=head2 execute


=cut

sub execute {
  my $self = shift;

  try {
    $self->_submit();
    if (!$self->interactive) {
      $self->_resume();
    }
  } catch {
    $self->logcroak('Error creating LSF jobs: ' . $_);
    $self->_kill_jobs();
  };

  return;
}

##################################################################
############## Private attributes ################################
##################################################################

has '_common_attrs' => (
  is         => 'ro',
  isa        => 'Str',
  lazy_build => 1,
);
sub _build__common_attrs {
  my $self = shift;
  # Using MooseX::AttributeCloner functionality
  my %attrs = %{$self->attributes_as_hashref()};
  my $meta = npg_pipeline::executor::lsf::job->meta();
  foreach my $attr_name (keys %attrs) {
    if (!$meta->find_attribute_by_name($attr_name)) {
      delete $attrs{$attr_name};
    }
  }
  return \%attrs;
}

##################################################################
############## Private methods ###################################
##################################################################

sub _string_job_ids2list {
  my $string_ids = shift;
  return (split /$LSF_JOB_IDS_DELIM/smx, $string_ids);
}

sub _list_job_ids2string {
  my @ids = @_;
  return @ids ? join $LSF_JOB_IDS_DELIM, @ids : q[];
}

sub _lsf_predesessors {
  my ($g, $v) = @_;
  #####
  # Recursive function. The recursion ends when we either
  # reach the start point - the vertext that has no predesessors -
  # or a vertex whose all predesessors are LSF jobs.
  #
  my @lsf_job_ids = ();
  foreach my $p (sort $g->predecessors($v)) {
    if ($g->has_vertex_attribute($p, $VERTEX_LSF_JOB_IDS_ATTR_NAME)) {
      push @lsf_job_ids, _string_job_ids2list(
        $g->get_vertex_attribute($p, $VERTEX_LSF_JOB_IDS_ATTR_NAME));
    } else {
      push @lsf_job_ids, _lsf_predesessors($g, $p);
    }
  }
  return @lsf_job_ids;
}

sub _resume {
  my $self = shift;

  my $g = $self->function_graph();
  my $suspended_start_job_id = $g->get_vertex_attribute(
     $SUSPENDED_START_FUNCTION, $VERTEX_LSF_JOB_IDS_ATTR_NAME);
  #####
  # If the pipeline_start job was used to keep all submitted jobs in pending
  # state and if the value of the interactive attribute is false, resume
  # the pipeline_start job thus allowing the pipeline jobs to start running.
  #
  if ($suspended_start_job_id) {
    $self->info(qq{Suspended start job, id $suspended_start_job_id});
    if (!$self->interactive) {
      $self->info(qq{Resuming start job, id $suspended_start_job_id});
      $self->_execute_lsf_command(qq{bresume $suspended_start_job_id});
    }
  } else {
    $self->warn(q{No suspended start job.});
  }

  return;
}

sub _kill_jobs {
  my $self = shift;

  my $g = $self->function_graph();
  my @job_ids =
    uniq
    reverse
    sort { $a <=> $b }
    map  { _string_job_ids2list($_) }
    grep { $g->get_vertex_attribute($_, $VERTEX_LSF_JOB_IDS_ATTR_NAME) }
    grep { $g->has_vertex_attribute($_, $VERTEX_LSF_JOB_IDS_ATTR_NAME) ? $_ : q[] }
    grep { $_ ne $SUSPENDED_START_FUNCTION }
    $g->vertices();

  if (@job_ids) {
    my $all_jobs = join q{ }, @job_ids;
    $self->info(qq{Will try to kill submitted jobs with following ids: $all_jobs});
    $self->_execute_lsf_command(qq{bkill -b $all_jobs});
  } else {
    $self->info(q{Early failure, no jobs to kill});
  }

  return;
}

sub _submit {
  my $self = shift;

  my $g = $self->function_graph;
  foreach my $function ($g->topological_sort()) {

    if (!exists $self->function_definitions()->{$function}) {
      #####
      # Probably a few function names were given explicitly.
      #
      $self->info(q{***** Function }.$function.q{ is not defined *****});
      next;
    }

    my $definitions = $self->function_definitions()->{$function};
    if (!$definitions) {
      $self->logcroak("No definition array for function $function");
    }
    if(!@{$definitions}) {
      $self->logcroak("Definition array for function $function is empty");
    }

    $self->info(q{***** Processing }.$function.q{ *****});
    if (@{$definitions} == 1) {
      my $d = $definitions->[0];
      if ($d->immediate_mode) {
        $self->info(q{***** Function }.$function.q{ has been already run *****});
        next;
      }
      if ($d->excluded) {
        $self->info(q{***** Function }.$function.q{ is excluded *****});
        next;
      }
    }

    #####
    # Need ids of upstream LSF jobs in order to set correctly dependencies
    # between LSF jobs
    #
    my @depends_on = ();
    if (!$g->is_source_vertex($function)) {
      @depends_on = _lsf_predesessors($g, $function);
      if (!@depends_on) {
        $self->logcroak(qq{"$function" should depend on at least one LSF job});
      }
    }

    my @ids = $self->_submit_function($function, @depends_on);
    if (!@ids) {
      $self->logcroak('A list of LSF job ids should be returned');
    }

    my $job_ids = _list_job_ids2string(@ids);
    $self->info(qq{Saving job ids: ${job_ids}\n});
    $g->set_vertex_attribute($function, $VERTEX_LSF_JOB_IDS_ATTR_NAME, $job_ids);
  }
  return;
}

sub _submit_function {
  my ($self, $function_name, @depends_on) = @_;

  return (1);
}

#####
# Executes LSF command, retrying a few times in case of failure.
# Error if cannnot execute the command.
# Recognises three LSF commands: bsub, bkill, bmod.
#
# For bsub command returns an id of the new LSF job. For other
# commands returns an empty string.
#
# If the no_bsub attribute is set to true, the LSF command (any,
# not only bsub) is not executed, default test job is is returned
# for bsub command.
#

sub _execute_lsf_command {
  my ($self, $cmd) = @_;

  $cmd ||= q[];
  $cmd =~ s/\A\s+//xms;
  $cmd =~ s/\s+\Z//xms;
  if (!$cmd) {
    $self->logcroak('command have to be a non-empty string');
  }

  if ($cmd !~ /\Ab(?: kill|sub|resume )\s/xms) {
    my $c = (split /\s/xms, $cmd)[0];
    $self->logcroak(qq{'$c' is not one of supported LSF commands});
  }

  my $job_id;
  my $error = 0;

  if ($self->no_bsub()) {
    $job_id =  $DEFAULT_JOB_ID_FOR_NO_BSUB;
  } else {
    my $count = 1;
    my $max_tries_plus_one =
      ($self->lsf_conf()->{'max_tries'} || $DEFAULT_MAX_TRIES) + 1;
    my $min_sleep = $self->lsf_conf()->{'min_sleep'} || $DEFAULT_MIN_SLEEP;

    while ($count < $max_tries_plus_one) {
      $job_id = qx/$cmd/;
      if ($CHILD_ERROR) {
        $error = 1;
        $self->error(qq{Error code $CHILD_ERROR. } .
                     qq{Error attempting ($count) to submit to LSF $cmd.});
        sleep $min_sleep ** $count;
        $count++;
      } else {
        $error = 0;
        $count = $max_tries_plus_one;
      }
    }
  }

  if ($error) {
    $self->logcroak('Failed to submit command to LSF');
  } else {
    if ($cmd =~ /\Absub/xms) {
      ($job_id) = $job_id =~ /(\d+)/xms;
    } else {
      $job_id = q[];
    }
  }

  return $job_id;
}

__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 DIAGNOSTICS

=head1 CONFIGURATION AND ENVIRONMENT

=head1 DEPENDENCIES

=over

=item List::MoreUtils

=item Moose

=item MooseX::StrictConstructor

=item namespace::autoclean

=item MooseX::AttributeCloner

=item namespace::autoclean

=item Sys::Filesystem::MountPoint

=item File::Spec

=item Try::Tiny

=item List::MoreUtils

=item Readonly

=item English

=item npg_tracking::illumina::runfolder

=item npg_tracking::util::abs_path

=item WTSI::DNAP::Utilities::Loggable

=back

=head1 INCOMPATIBILITIES

=head1 BUGS AND LIMITATIONS

=head1 AUTHOR

=over

=item Andy Brown

=item Marina Gourtovaia

=back

=head1 LICENSE AND COPYRIGHT

Copyright (C) 2018 Genome Research Ltd.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
