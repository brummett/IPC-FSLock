package IPC::FSLock;

use strict;
use warnings;

use IO::File;
use Fcntl qw(LOCK_EX LOCK_NB LOCK_SH);
use Errno qw(EEXIST ENOTEMPTY ENOENT);
use Time::HiRes qw(sleep);
use Sys::Hostname;
use Carp;


sub create {
    my($class,%params) = @_;

    # Verify input params.  Expected: lock_type, path, sleep, timeout
    my $type_flags = delete $params{'lock_type'};
    $type_flags = LOCK_EX unless (defined $type_flags);  # default exclusive lock
    my $is_exclusive_lock = $type_flags & LOCK_EX;
    my $is_shared_lock    = $type_flags & LOCK_SH;
    my $is_non_blocking   = $type_flags & LOCK_NB;

    if ($is_exclusive_lock and $is_shared_lock) {
        Carp::croak "Can't create a lock that is both shared and exclusive";
    }

    my $resource_lock_dir = delete $params{'path'};
    unless (defined $resource_lock_dir) {
        Carp::croak "path is a required parameter";
    }
    $resource_lock_dir .= '/';

    my $sleep = delete $params{'sleep'};
    $sleep ||= 60;  # sleep time between attempts.  Don't allow 0

    my $retry_forever;
    my $timeout_time = delete $params{'timeout'};

    if (defined($timeout_time) and $sleep > $timeout_time) {
        $sleep = $timeout_time;
    }

    if (defined $timeout_time) {
        $retry_forever = 0;
        $timeout_time += time();
    } else {
        $retry_forever = 1;
    }

    if (keys %params) {
        Carp::croak("Unrecognized params: ".join(', ',keys %params));
    }

    # Done parsing parameters

    my $self = { is_exclusive => $is_exclusive_lock,
                 resource_lock_dir => $resource_lock_dir,
                 pid => $$,
               };
    bless $self, $class;

    # Make the top-level directory for all locks on this resource
    unless (mkdir $resource_lock_dir) {
        if ($! != EEXIST) {
            Carp::croak("Can't create lock directory $resource_lock_dir: $!");
        }
    }
    unless (-d $resource_lock_dir) {
        Carp::croak("Lock directory $resource_lock_dir exists, but is not a directory");
    }

    # Figure out the reservation directory/file names
    my $timeofday = Time::HiRes::gettimeofday;
    my $hostname = Sys::Hostname::hostname();
    if ($self->is_shared) {
        unless ( ($self->{'reservation_dir'}) = (glob($resource_lock_dir . "shared-*/"))[-1] ) {
            $self->{'reservation_dir'} = $resource_lock_dir . sprintf('shared-%s-pid%d-%s/',$hostname,$$,$timeofday);
        } 
        $self->{'reservation_file'} = $self->{'reservation_dir'} .
                                  sprintf('%s-pid%d-%s',
                                          $hostname,
                                          $$,
                                          $timeofday);
    } else {
        # exclusive
        $self->{'reservation_dir'} = $resource_lock_dir .
                                 sprintf('excl-%s-pid%d-%s/',
                                         $hostname,
                                         $$,
                                         $timeofday);
    }
                       
    # Declare my intention to lock
    return unless
        $self->_create_reservation($retry_forever, $timeout_time, $sleep, $is_non_blocking);

    # Try to acquire the lock
    my $wanted_symlink = $self->{'resource_lock_dir'} . 'lock';
    return unless
        $self->_acquire_lock($wanted_symlink, $retry_forever, $timeout_time, $sleep, $is_non_blocking);

    return $self;
}


sub _acquire_lock {
    my($self, $wanted_symlink, $retry_forever, $timeout_time, $sleep, $is_non_blocking) = @_;

    ACQUIRE: {
        do {
            # if no symlink existed before, this will succeed and we have the lock
            last if $self->_create_lock_symlink($wanted_symlink);

            if ($self->is_shared) {
                # For sh locks, there may already be another sh lock active
                # see if the symlink points to the shared/ directory
                # If the link disappeard between the above symlink() and now, that's ok
                # we'll just try again on the next iteration

                # another sh has the lock, we're ok to go
                last if ($self->_read_lock_symlink($wanted_symlink) eq $self->{'reservation_dir'});
            }
            
            last if ($is_non_blocking);

            sleep $sleep;
        } while ($retry_forever or time <= $timeout_time);
    }

    return unless (readlink($wanted_symlink) eq $self->{'reservation_dir'});

    $self->{'symlink'} = $wanted_symlink;

    return 1;
}
    
sub _create_lock_symlink {
    my($self, $wanted_symlink) = @_;

    my $rv = symlink $self->{'reservation_dir'}, $wanted_symlink;
    if (!$rv and $! != EEXIST) {
        Carp::croak("Can't create lock symlink $wanted_symlink: $!");
    }
    return $rv;
}

sub _read_lock_symlink {
    my($self, $wanted_symlink) = @_;

    $wanted_symlink = $self->{'symlink'} unless defined $wanted_symlink;

    my $points_to = readlink $wanted_symlink;
    # The symlink may have disappeared between the attempt to create it and
    # now.  That is the only OK reason readlink may have failed
    if (! defined($points_to) and $! != ENOENT) {
        Carp::croak("Can't readlink the lock symlink $wanted_symlink: $!");
    }
    return $points_to;
}
        

sub _create_reservation {
    my($self, $retry_forever, $timeout_time, $sleep, $is_non_blocking) = @_;

    RESERVE: {
        do {
            $self->_create_reservation_directory;
            last if $self->is_exclusive;

            # shared also drop a file in the shared/ directory
            last if $self->_create_reservation_file;

            last if $is_non_blocking;   # FIXME - seems we might actually want to stay in this loop...

            sleep $sleep;
        } while ($retry_forever or time <= $timeout_time);
    }

    return $self->_has_reservation;
}

sub _create_reservation_directory {
    my $self = shift;

    unless (mkdir $self->{'reservation_dir'}) {
        # Exclusive locks should always succeed 
        # Shared locks may fail only if that path already exists
        if ($self->is_exclusive or ($self->is_shared and $! != EEXIST)) {
            Carp::croak("Can't make reservation directory for lock ".$self->{'reservation_dir'}.": $!");
        }
    }
    return 1;
}
    
sub _create_reservation_file {
    my $self = shift;

    my $fh = IO::File->new($self->{'reservation_file'}, 'w');
    if ($fh) {
        $fh->close();
        return 1;
    } else {
        if ($! != ENOENT) {  # ENOENT means some part of the path didn't exist
            Carp::croak("Can't create reservation file ".$self->{'reservation_file'}.": $!");
        }
        return;
    }
}
    


sub _remove_reservation_file {
    my $self = shift;

    if (defined $self->{'reservation_file'}) {
        unless (unlink $self->{'reservation_file'}) {
            Carp::croak("Couldn't remove reservation file ".$self->{'reservation_file'}.": $!");
        }
    }
    return 1; 
}

sub _remove_reservation_directory {
    my $self = shift;

    my $rv;
    if (defined $self->{'reservation_dir'}) {
        $rv = rmdir $self->{'reservation_dir'};
        if (! $rv and $! != ENOTEMPTY) {
            Carp::croak("Can't remove reservation directory ".$self->{'reservation_dir'}.": $!");
        }
    }
    return $rv;
}

sub _remove_lock_symlink {
    my $self = shift;

    if (defined $self->{'symlink'}) {
        unless (unlink $self->{'symlink'}) {
            Carp::croak("Couldn't remove lock symlink ".$self->{'symlink'}.": $!");
        }
    }
    return 1;
}

sub _remove_resource_lock_directory {
    my $self = shift;

    if (defined $self->{'resource_lock_dir'}) {
        unless (rmdir $self->{'resource_lock_dir'}) {
            if ($! != ENOTEMPTY) {
                Carp::croak("Can't remove resource lock directory ".$self->{'resource_lock_dir'}.": $!");
            }
        }
    }
    return 1;
}


sub is_lock_mine {
    my $self = shift;

    return unless($self->is_valid and $self->{'symlink'});

    my $symlink = $self->{'symlink'};
    unless (-e $symlink) {
        Carp::carp("Lock is_valid, but the symlink $symlink does not exist");
        return;
    }

    unless (-l $symlink) {
        Carp::carp("Lock is_valid, but $symlink is not actually a symlink");
        return;
    }

    my $points_to = $self->_read_lock_symlink;
    return unless $points_to;

    my $hostname = Sys::Hostname::hostname;
    if ($self->is_exclusive) {
        return $points_to =~ m/excl-$hostname-pid$$/;
    } else {
        return unless ($points_to =~ m/shared-/);
        return unless (index($self->{'reservation_file'}, $points_to) >= 0);
        return unless (-f $self->{'reservation_file'});
    }
}


sub unlock {
    my $self = shift;

    return unless $self->is_valid;

    # After a fork(), only the parent should be allowed to unlock?
    return unless $self->{'pid'} == $$; 

    unless ($self->is_lock_mine) {
        Carp::carp("Lock symlink ".$self->{'symlink'}." does not appear to be owned by me");
    }

    $self->_do_unlock();
}

sub _do_unlock {
    my $self = shift;

    if ($self->is_shared) {
        # shared locks, first remove their file inside the shared/ directory
        $self->_remove_reservation_file;

        # Remove the reservation directory
        my $rv = $self->_remove_reservation_directory;

        # There's a tiny window here where the lock symlink exists, but points to
        # a non-existent shared reservation directory.  Hope we don't crash and
        # leave the lock hanging.  There's probably not much we can do to prevent this.
        
        # If that worked, we were the last shared lock, remove the lock symlink
        if ($rv) {
            $self->_remove_lock_symlink;
        }

    } else {
        # excl locks
        
        # We can safely remove the lock symlink first, giving up the lock
        $self->_remove_lock_symlink;

        # Remove our dir to clean up
        $self->_remove_reservation_directory;
    }

    # If we're the last for this resource, clean up
    # FIXME - this can go back in if we add the resource directory creation to the
    # looping constructs in create()
    #$self->_remove_resource_lock_directory;

    # make ourselves invalid
    delete $self->{$_} foreach keys %$self;

    return 1;
}



sub DESTROY {
    goto &_do_unlock;
}


sub is_locked {
    my($class, $path) = @_;

    $path .= '/lock';
    return -e $path;
}


sub is_shared {
    return ! $_[0]->{'is_exclusive'};
}

sub is_exclusive {
    return $_[0]->{'is_exclusive'};
}

sub is_valid {
    return keys %{$_[0]};
}


sub _has_reservation {
    my $self = shift;

    return unless (-d $self->{'reservation_dir'});
    if ($self->is_shared) {
        return unless (-f $self->{'reservation_file'});
    }

    return 1;
}

sub _symlink_path {
    my $self = shift;

    return $self->{'resource_lock_dir'} . '/lock';
}
    

1;
