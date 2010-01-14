package FileLock;

use strict;
use warnings;

use IO::File;

our $LOCK_DIR_BASE;

BEGIN {
    $LOCK_DIR_BASE = '/tmp/locks';
    mkdir($LOCK_DIR_BASE);
}

sub create {
    my($class,%params) = @_;

    # Verify input params.  Expected: style, resource, sleep, timeout
    unless ($params{'style'} eq 'sh' or $params{'style'} eq 'ex') {
        die "style not sh or ex";
    }

    unless ($params{'resource'}) {
        die "no resource";
    }

    $params{'sleep'} ||= 1;  # sleep time between attempts.  Don't allow 0

    my $retry_forever;
    my $timeout_time;
    if (defined $params{'timeout'}) {
        $retry_forever = 0;
        $timeout_time = time() + $params{'timeout'};
    } else {
        $retry_forever = 1;
    }

    my $resource_lock_dir = $LOCK_DIR_BASE . '/' . $params{'resource'} . '/';
    mkdir $resource_lock_dir;

    my $self = { style => $params{'style'},
                 resource_lock_dir => $resource_lock_dir,
               };
    bless $self, $class;

    if ($params{'style'} eq 'sh') {
        $self->{'reservation_dir'} = $resource_lock_dir . 'shared/';
        $self->{'reservation_file'} = $self->{'reservation_dir'} .
                                  sprintf('%s-pid%d-%d',
                                          $ENV{'HOST'},
                                          $$,
                                          time());
    } else {
        # exclusive
        $self->{'reservation_dir'} = $resource_lock_dir .
                                 sprintf('writer-%s-pid%d-%d/',
                                         $ENV{'HOST'},
                                         $$,
                                         time());
    }
                       
    # Declare my intention to lock
    # make a lock directory as a reservation
    RESERVE: {
        do {
            mkdir $self->{'reservation_dir'};
            last if $self->{'style'} eq 'ex';

            # shared also drop a file in the shared/ directory
            my $fh = IO::File->new($self->{'reservation_file'}, 'w');
            if ($fh) {
                $fh->close();
                last;
            }
            sleep $params{'sleep'};
        } while ($retry_forever or time <= $timeout_time);
    }

    return unless $self->_has_reservation;

    # Try to aquire the lock
    my $wanted_symlink = $class->_symlink_path_for_resource($params{'resource'});
    AQUIRE: {
        do {
            # if no symlink existed before, this will succeed and we have the lock
            last if symlink $self->{'reservation_dir'}, $wanted_symlink;  # got the lock

            if ($params{'style'} eq 'sh') {
                # For sh locks, there may already be another sh lock active
                # see if the symlink points to the shared/ directory
                my $points_to = readlink $wanted_symlink;
                last if ($points_to eq $self->{'reservation_dir'});   # another sh has the lock, we're ok to go
            }

            sleep $params{'sleep'};
        } while ($retry_forever or time <= $timeout_time);
    }

    return unless (readlink($wanted_symlink) eq $self->{'reservation_dir'});

    $self->{'symlink'} = $wanted_symlink;

    return $self;
}


sub unlock {
    my $self = shift;

    # shared locks, first remove their file inside the shared/ directory
    if ($self->{'style'} eq 'sh') {
        unlink $self->{'reservation_file'};
    }

    # Next, remove the lock directory.  
    # For ex locks, this will always succeed
    # for sh locks, this will fail if another also has a sh lock
    my $rv = rmdir $self->{'reservation_dir'};
    if ($rv) {
        # If directory was removed, then the lock can be declared free
        # remove the symlink
        unlink $self->{'symlink'} if ($self->{'symlink'});
    }

    rmdir $self->{'resource_lock_dir'};

    # make ourselves invalid
    delete $self->{$_} foreach keys %$self;

    return 1;
}
            

sub DESTROY {
    goto &unlock;
}
        
    

sub is_locked {
    my($class, $resource_id) = @_;

    my $path = $class->_symlink_path_for_resource($resource_id);
    return -e $path;
}


sub is_shlock {
    return $_[0]->{'style'} eq 'sh';
}

sub is_exlock {
    return $_[0]->{'style'} eq 'ex';
}

sub is_valid {
    return keys %{$_[0]};
}


sub _has_reservation {
    my $self = shift;

    return unless (-d $self->{'reservation_dir'});
    if ($self->{'style'} eq 'sh') {
        return unless (-f $self->{'reservation_file'});
    }

    return 1;
}
    
sub _symlink_path_for_resource {
    my($self,$resource) = @_;

    
    unless (defined $resource) {
        # obj method
        $resource = $self->{'resource'};
    }
    return $LOCK_DIR_BASE . '/' . $resource . '/lock';
}

1;
    
