use strict;
use warnings;

use IPC::FSLock;
use Fcntl qw(LOCK_EX LOCK_NB LOCK_SH);
use Test::More tests => 7;

use File::Temp;

my $temp_dir = File::Temp::tempdir(CLEANUP => 1);

our $path = $temp_dir . '/foo/';

$SIG{'ALRM'} = sub { ok(0, 'Got alarm'); exit };

# The race-critical parts of the locking state machine goes like this:
# Get a lock:
# A: _create_reservation()
# 1. _create_reservation_directory
#     exclusive locks should always succeed
#     shared locks can only fail if $! == EEXIST
#     always goto 2
# 2. _create_reservation_file
#     exclusive locks don't do this
#     shared locks can only fail if $! == ENOENT
#     pass: goto 3
#     fail: goto 1
# B: _acquire_lock()
# 3. _create_lock_symlink
#     symlink() may only fail due to EEXIST
#     pass: Return successful lock to caller
#     fail: shared goto 4, exclusive goto 3
# 4. _read_lock_symlink
#     exclusive locks don't do this, they go back to step 3
#     readlink() may only fail due to ENOENT
#     pass: give readlink result to step 5, 
#     fail: goto 3
# 5. step 4 output must eq $self->{'reservation_file'}
#    exclusive locks don't do this
#    pass: Return successful lock to caller
#    fail: goto 3
#
# Unlock shared lock:
# 1. _remove_reservation_file
#     must always succeed
# 2. _remove_reservation_directory
#     may only fail due to ENOTEMPTY
#     pass: goto 3
#     fail: return successful unlock
# 3. _remove_lock_symlink
#     must always succeed
# Unlocked successfully
#
# Unlock exclusive lock:
# 1. _remove_lock_symlink
#     must always succeed, goto 2
# 2. remove_reservation_directory
#     must always succeed
# Unlocked successfully


ok(mkdir($path), 'Created lock directory');

ok(&test_two_locks($path, 'IPC::FSLock::ExclLockStateMachine', 'IPC::FSLock::NullStateMachine'),
   'Testing one exclusive lock');

ok(&test_two_locks($path, 'IPC::FSLock::SharedLockStateMachine', 'IPC::FSLock::NullStateMachine'),
   'Testing one shared lock');

ok(&test_two_locks($path, 'IPC::FSLock::SharedLockStateMachine', 'IPC::FSLock::SharedLockStateMachine'),
   'Testing two shared locks');

ok(&test_two_locks($path, 'IPC::FSLock::ExclLockStateMachine', 'IPC::FSLock::SharedLockStateMachine'),
   'Testing exclusive lock and shared lock');

ok(&test_two_locks($path, 'IPC::FSLock::SharedLockStateMachine', 'IPC::FSLock::ExclLockStateMachine'),
   'Testing shared lock and exclusive lock');

ok(&test_two_locks($path, 'IPC::FSLock::ExclLockStateMachine', 'IPC::FSLock::ExclLockStateMachine'),
   'Testing two exclusive locks');



sub test_two_locks {
    my($lock_dir, $lock_type_1, $lock_type_2) = @_;

    my $type1_nodes = $lock_type_1->nodes;
    my $type1_node_count = scalar(keys %$type1_nodes);
    my $type2_nodes = $lock_type_2->nodes;
    my $type2_node_count = scalar(keys %$type2_nodes);

    my $max_reps;
    if ($type1_node_count > $type2_node_count) {
        $max_reps = 1 << $type1_node_count;
    } else {
        $max_reps = 1 << $type2_node_count;
    }

    CHECK_PERMUTATIONS:
    for (my $current_path = 0; $current_path < $max_reps; $current_path++) {

        my $lock1 = IPC::FSLock->_setup_object({ is_exclusive => ($lock_type_1 =~ m/Excl/) ? 1 : 0,
                                                 resource_lock_dir => $lock_dir,
                                                 pid => 123,
                                             });
        my $lock2;
        if ($lock_type_2 ne 'IPC::FSLock::NullStateMachine') { 
            $lock2 = IPC::FSLock->_setup_object({ is_exclusive => ($lock_type_2 =~ m/Excl/) ? 1 : 0,
                                                  resource_lock_dir => $lock_dir,
                                                  pid => 456,
                                              });
        }

        my $machine1 = $lock_type_1->new($lock1);
        my $machine2 = $lock_type_2->new($lock2);

        my($result, $reason) = eval { &run_machines_with_path($current_path, $machine1, $machine2) };
        unless ($result) {
            diag "Path $current_path failed.  Reason: $reason  Exception: $@";
            return;
        }
    }
    return 1;
}

sub run_machines_with_path {
    my($this_path,@machines) = @_;

    my $current_bit = 0;
    my %transitions;

    while(grep { ! $_->is_done } @machines) {
        my $mask = 1 << $current_bit++;

        my $which = ($this_path & $mask) ? 1 : 0;
        if ($machines[$which]->is_done) {
            $which = !$which;
        }
        $machines[$which]->do_next_state;

        my $current_state = join(':',map { $_->last_state } @machines);
        if ($transitions{$current_state}++) {
            return (0, 'Looping state detected');
        }
    }
    return (1,'Done');
}


package IPC::FSLock::StateMachine;

sub new {
    my($class, $obj) = @_;

    my $self = bless { obj => $obj, state => 'new', result => 1 }, $class;
    return $self;
}

sub last_state {
    return $_[0]->{'state'};
}

sub last_result {
    return $_[0]->{'result'};
}

sub is_done {
    my $self = shift;
    my $state = $self->last_state;
    return ($state eq 'done') || ($state eq 'do_nothing');
}

sub do_next_state {
    my $self = shift;

    my $nodes = $self->nodes;
    my $current_node = $nodes->{$self->last_state};
    my $next_state = $self->last_result ? $current_node->{'pass'} : $current_node->{'fail'};

    if ($next_state eq 'die') {
        die "Got into 'die' state";

    } elsif ($next_state eq 'do_nothing') {
        $self->{'state'} = 'do_nothing';
        return 1;

    } elsif ($next_state ne 'done') {
        alarm(5) unless ($^P);
        my $rv = $self->{'obj'}->$next_state;
        alarm(0);
        $self->{'result'} = $rv;
        $self->{'state'} = $next_state;
    } elsif ($next_state eq 'done') {
        $self->{'result'} = 1;
        $self->{'state'} = 'done';
    }
    return $self->{'result'};
}


package IPC::FSLock::SharedLockStateMachine;
use base 'IPC::FSLock::StateMachine';

sub nodes {
    return { 'new' => {
                        pass => '_create_reservation_directory',
                      },
             '_create_reservation_directory' => {
                        pass => '_create_reservation_file',
                        fail => '_create_reservation_file',
                       },
             '_create_reservation_file' => {
                        pass => '_create_lock_symlink',
                        fail => '_create_reservation_directory',
                       },
             '_create_lock_symlink' => {
                        pass => '_verify_lock_symlink',
                        fail => '_verify_lock_symlink',
                      },
             '_verify_lock_symlink' => {
                        pass => '_remove_reservation_file',
                        fail => '_create_lock_symlink',
                       },
             '_remove_reservation_file' => {
                        pass => '_remove_reservation_directory',
                        fail => 'die',
                      },
             '_remove_reservation_directory' => {
                         pass => '_remove_lock_symlink',
                         fail => 'done',
                      },
             '_remove_lock_symlink' => {
                          pass => 'done',
                          fail => 'die',
                       },
            };
}



package IPC::FSLock::ExclLockStateMachine;
use base 'IPC::FSLock::StateMachine';

sub nodes {
    return { 'new' => {
                        pass => '_create_reservation_directory',
                      },
             '_create_reservation_directory' => {
                        pass => '_create_lock_symlink',
                        fail => 'die',
                       },
             '_create_lock_symlink' => {
                        pass => '_verify_lock_symlink',
                        fail => '_create_lock_symlink',
                      },
             '_verify_lock_symlink' => {
                        pass => '_remove_lock_symlink',
                        fail => '_create_lock_symlink',
                       },
             '_remove_lock_symlink' => {
                          pass => '_remove_reservation_directory',
                          fail => 'die',
                       },
             '_remove_reservation_directory' => {
                         pass => 'done',
                         fail => 'die',
                      },
            };
}

package IPC::FSLock::NullStateMachine;
use base 'IPC::FSLock::StateMachine';

sub nodes {
    return { 'new' => {
                         pass => 'do_nothing',
                      },
             'do_nothing' => {
                         pass => 'do_nothing',
                      },
           };
}

