use strict;
use warnings;

use IPC::FSLock;
use Fcntl qw(LOCK_EX LOCK_NB LOCK_SH);
use Test::More tests => 17;

use File::Temp;

my $temp_dir = File::Temp::tempdir(CLEANUP => 1);

our $path = $temp_dir . '/foo';

$SIG{'ALRM'} = sub { ok(0, 'Got alarm'); exit };
alarm(1);
my $lock = IPC::FSLock->create(path => $path, lock_type => LOCK_SH, timeout => 100);
alarm(0);
ok($lock, 'Created lock with default values');
ok(IPC::FSLock->is_locked($path), 'is locked');
ok($lock->is_shared, 'is shared lock');
ok(! $lock->is_exclusive, 'is not exclusive');
ok($lock->is_valid, 'is valid');


my $lock2 = try_lock(LOCK_SH, 1, 'Got another shared lock');

my $ex_lock = try_lock(LOCK_EX, 0, 'Cannot get exclusive lock');

ok($lock->unlock, 'unlocked first shared lock');

$ex_lock = try_lock(LOCK_EX, 0, 'Still cannot get exclusive lock');

my $lock3 = try_lock(LOCK_SH, 1, 'Got a third shared lock');

$ex_lock = try_lock(LOCK_EX, 0, 'Still cannot get exclusive lock');

ok($lock2->unlock, 'Unlocked second lock');

$ex_lock = try_lock(LOCK_EX, 0, 'Still cannot get exclusive lock');

ok($lock3->unlock,'Unlocked third lock');

$ex_lock = try_lock(LOCK_EX, 1, 'Now got exclusive lock');

my $ex_lock2 = try_lock(LOCK_EX, 0, 'Cannot get another exclusive lock');

my $sh_lock2 = try_lock(LOCK_SH, 0, 'Cannot get another shared lock');


sub try_lock {
    my($type, $should_work, $msg) = @_;

    alarm(2);
    my $lock = IPC::FSLock->create(path => $path, lock_type => $type, timeout => 0.1);
    alarm(0);

    if($should_work) {
        ok($lock, $msg);
    } else {
         ok(! $lock, $msg);
    }

    return $lock;
}
