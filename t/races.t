use strict;
use warnings;

use IPC::FSLock;
use Fcntl qw(LOCK_EX LOCK_NB LOCK_SH);
use Test::More skip_all => 'Not done yet';

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



# Fake up a couple of "lock" objects;
ok(mkdir($path), 'Created lock directory');
my $excl_lock1 = IPC::FSLock->_setup_object({ is_exclusive => 1,
                                              resource_lock_dir => $path,
                                              pid => 123,
                                            });
my $excl_lock2 = IPC::FSLock->_setup_object({ is_exclusive => 1,
                                              resource_lock_dir => $path,
                                              pid => 234,
                                            });
my $shared_lock1 = IPC::FSLock->_setup_object({ is_exclusive => 0,
                                                resource_lock_dir => $path,
                                                pid => 345,
                                              });
my $shared_lock2 = IPC::FSLock->_setup_object({ is_exclusive => 0,
                                                resource_lock_dir => $path,
                                                pid => 456,
                                              });
ok($excl_lock1 && $excl_lock2 && $shared_lock1 && $shared_lock2,
   "Created raw lock objects"); 

#my $retry_forever = 0;
#my $timeout_time = 1;
#my $sleep = 0.1;
#my $is_non_blocking = 0;
my $wanted_symlink = $path . 'lock';

# Easy - lock and unlock excl lock
ok($excl_lock1->_create_reservation_directory, '$excl_lock1->_create_reservation_directory');
ok($excl_lock1->_create_lock_symlink($wanted_symlink), '$excl_lock1->_create_lock_symlink($wanted_symlink)');
ok($excl_lock1->_remove_lock_symlink, '$excl_lock1->_remove_lock_symlink');
ok($excl_lock1->_remove_reservation_directory, '$excl_lock1->_remove_lock_symlink');

ok($excl_lock1->_create_reservation_directory, '$excl_lock1->_create_reservation_directory');
ok($excl_lock2->_create_reservation_directory, '$excl_lock2->_create_reservation_directory');
ok($excl_lock1->_create_lock_symlink($wanted_symlink), '$excl_lock1->_create_lock_symlink($wanted_symlink)');
ok(! $excl_lock2->_create_lock_symlink($wanted_symlink), '! $excl_lock2->_create_lock_symlink($wanted_symlink)');




sub do_state_transisitions {
    my(@machines) = @_;
    # only works on 2 machines

    my %done_transisitions;

    CHECK_PERMUATATIONS:
    for (my $current_path = 0; ; $current_path++) {

        my($result, $reason) = &run_machines_with_path($current_path, @machines);

        CRANK_MACHINES:
        while(grep { ! $_->is_done } @machines) {
            $current_bit = 0;
            my $mask = 1 << $current_bit;
            my $which = $current_path & $mask;

            $machine[$which]->do_next_state;

sub run_machines_with_path {
    my($this_path,@machines) = @_;

    my $current_bit = 0;
    my %transitions;

    while(grep { ! $_->is_done } @machines) {
        my $mask = 1 << $current_bit++;

        my $which = $this_path & $mask;
        $machines[$which]->do_next_state;

        my $current_state = join(':',map { $_->last_state } @machines);
        if ($transitions{$current_state}++) {
            return (0, 'Looping state detected');
        }
    }
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
    return $state eq 'done' or $state eq 'no_nothing';
}

sub do_next_state {
    my $self = shift;

    my $nodes = $self->nodes;
    my $current_node = $nodes->{$self->last_state};
    my $next_state = $self->last_result ? $current_node->{'pass'} : $current_node->{'fail'};

    if ($next_state eq 'die') {
        die "Got into 'die' state";

    } elsif ($next_state eq 'no_nothing') {
        return 1;

    } elsif ($next_state ne 'done') {
        my $rv = $self->{'obj'}->$next_state;
        $self->{'result'} = $rv;
        $self->{'state'} = $next_state;
    }
    return $self->{'result'};
}


package IPC::FSLock::SharedLockStateMachine;
our @ISA = qw( IPC::FSLock::StateMachine );

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
our @ISA = qw( IPC::FSLock::StateMachine );

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
our @ISA = qw( IPC::FSLock::StateMachine );

sub nodes {
    return { 'new' => {
                         pass => 'do_nothing',
                      },
             'do_nothing' => {
                         pass => 'do_nothing',
                      },
           };
}

