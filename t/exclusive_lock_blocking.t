use strict;
use warnings;

use IPC::FSLock;
use Fcntl qw(LOCK_EX LOCK_NB LOCK_SH);
use Test::More tests => 14;

use File::Temp;

my $temp_dir = File::Temp::tempdir(CLEANUP => 1);

my $path = $temp_dir . '/foo';

$SIG{'ALRM'} = sub { ok(0, 'Alarm signal'); exit;};
alarm(1);
my $lock = IPC::FSLock->create(path => $path, lock_type => LOCK_EX);
alarm(0);
ok($lock, 'Created exclusive lock');
ok($lock->is_valid, 'lock is valid');

alarm(1);
my $lock2 = IPC::FSLock->create(path => $path, lock_type => LOCK_EX | LOCK_NB, 'sleep' => 1);
alarm(0);
ok(! $lock2, "Could not create another exclusive lock, (probably) didn't block");

alarm(1);
$lock2 = IPC::FSLock->create(path => $path, lock_type => LOCK_SH | LOCK_NB, 'sleep' => 1);
alarm(0);
ok(! $lock2, "Could not create another shared lock, (probably) didn't block");

my $before_time = time();
alarm(5);
$lock2 = IPC::FSLock->create(path => $path, lock_type => LOCK_EX, timeout => 2, 'sleep' => 1);
alarm(0);
my $after_time = time();
ok(! $lock2, "Couldn't create another exclusive lock");
ok($after_time > $before_time, 'It waited at some time');

$before_time = time();
alarm(5);
$lock2 = IPC::FSLock->create(path => $path, lock_type => LOCK_SH, timeout => 2, 'sleep' => 1);
alarm(0);
$after_time = time();
ok(! $lock2, "Couldn't create another shared lock");
ok($after_time > $before_time, 'It waited some time');


my $alarmed = 0;
$SIG{'ALRM'} = sub {$alarmed = 1;};
$before_time = time();
alarm(1);
$lock2 = IPC::FSLock->create(path => $path, lock_type => LOCK_EX, timeout => 3, 'sleep' => 1);
alarm(0);
$after_time = time();
ok(! $lock2, "Couldn't create another exclusive lock");
ok($after_time > $before_time, 'It waited some time');
ok($alarmed, 'waited at least 1 second');

$alarmed = 0;
$before_time = time();
alarm(1);
$lock2 = IPC::FSLock->create(path => $path, lock_type => LOCK_SH, timeout => 3, 'sleep' => 1);
alarm(0);
$after_time = time();
ok(! $lock2, "Couldn't create another shared lock");
ok($after_time > $before_time, 'It waited some time');
ok($alarmed, 'waited at least 1 second');




