use strict;
use warnings;

use IPC::FSLock;
use Fcntl qw(LOCK_EX LOCK_NB LOCK_SH);
use Test::More tests => 15;

use File::Temp;

my $temp_dir = File::Temp::tempdir(CLEANUP => 1);

my $path = $temp_dir . '/foo';

$SIG{'ALRM'} = sub { ok(0, 'Got alarm'); exit };
alarm(1);
my $lock = IPC::FSLock->create(path => $path, lock_type => LOCK_EX);
alarm(0);
ok($lock, 'Created lock');
ok(IPC::FSLock->is_locked($path), 'is locked');
ok(!$lock->is_shared, 'is not shared lock');
ok($lock->is_exclusive, 'is exclusive');
ok($lock->is_valid, 'is valid');

ok(-d $path, 'lock path exists');
my $expected_symlink = $path . '/lock';
ok(-e $expected_symlink, 'lock symlink exists');
my $expected_reservation = $lock->{'reservation_dir'};
ok(-d $expected_reservation, 'reservation directory exists');
is(readlink($expected_symlink), $expected_reservation, 'symlink points to reservation dir');
ok(! exists $lock->{'reservation_file'}, 'exclusive locks have no reservation file');

ok($lock->unlock, 'unlock');
ok(!$lock->is_valid, 'lock is now invalid');

ok(-d $path, 'lock path still exists');
ok(!-e $expected_symlink, 'symlink is gone');
ok(!-d $expected_reservation, 'reservarion directory is gone');

