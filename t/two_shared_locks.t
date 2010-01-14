use strict;
use warnings;

use IPC::FSLock;
use Fcntl qw(LOCK_EX LOCK_NB LOCK_SH);
use Test::More tests => 29;

use File::Temp;

my $temp_dir = File::Temp::tempdir(CLEANUP => 1);

my $path = $temp_dir . '/foo';

$SIG{'ALRM'} = sub { ok(0, 'Got alarm'); exit };
alarm(1);
my $lock = IPC::FSLock->create(path => $path, lock_type => LOCK_SH);
alarm(0);
ok($lock, 'Created lock with default values');
ok(IPC::FSLock->is_locked($path), 'is locked');
ok($lock->is_shared, 'is shared lock');
ok(! $lock->is_exclusive, 'is not exclusive');
ok($lock->is_valid, 'is valid');

ok(-d $path, 'lock path exists');
my $expected_symlink = $path . '/lock';
ok(-e $expected_symlink, 'lock symlink exists');
my $expected_reservation = $lock->{'reservation_dir'};
ok(-d $expected_reservation, 'reservation directory exists');
is(readlink($expected_symlink), $expected_reservation, 'symlink points to reservation dir');
my $lock1_file = $lock->{'reservation_file'};
ok(-f $lock1_file, 'reservation file exists');


alarm(1);
my $lock2 = IPC::FSLock->create(path => $path, lock_type => LOCK_SH);
alarm(0);
ok($lock2, 'Got another shared lock');
is($lock2->{'reservation_dir'}, $lock->{'reservation_dir'}, 'Both locks have the same reservation directory');
my $lock2_file = $lock2->{'reservation_file'};
isnt($lock2_file, $lock1_file, 'Both locks have different reservation files');
is(readlink($expected_symlink), $expected_reservation, 'symlink still points to reservation dir');


ok($lock->unlock, 'unlocked first lock');
ok(!$lock->is_valid, 'first lock is now invalid');
ok($lock2->is_valid, 'second lock is still valid');
ok(-d $path, 'lock path exists');
ok(-e $expected_symlink, 'lock symlink exists');
ok(-d $expected_reservation, 'reservation directory exists');
is(readlink($expected_symlink), $expected_reservation, 'symlink points to reservation dir');
ok(! -e $lock1_file, 'first lock reservation file is gone');
ok(-f $lock2_file, 'second lock reservation file exists');


ok($lock2->unlock, 'unlock second lock');
ok(! $lock2->is_valid, 'second lock now invalid');
ok(-d $path, 'lock path still exists');
ok(!-e $expected_symlink, 'symlink is gone');
ok(!-d $expected_reservation, 'reservarion directory is gone');
ok(!-f $lock2_file, 'reservation file is gone');

