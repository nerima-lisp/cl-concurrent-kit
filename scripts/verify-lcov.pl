use v5.34;
use File::Basename qw(basename);

my ($lcov_file, $source_root) = @ARGV;
die "Usage: verify-lcov.pl LCOV-FILE SOURCE-ROOT\n"
  unless defined $lcov_file && defined $source_root && !@ARGV;

# PACKAGE.LISP contains package/declaration forms only. SB-COVER does not
# emit an executable record for it, so every other implementation file must
# appear exactly once in LCOV.
my @expected_sources = map { basename $_ }
  grep { basename($_) ne 'package.lisp' } glob "$source_root/src/*.lisp";
die "No implementation sources found below $source_root/src\n"
  unless @expected_sources;
my %expected_source = map { $_ => 1 } @expected_sources;
my %permitted_source = (%expected_source, 'package.lisp' => 1);

open my $lcov, '<', $lcov_file or die "Cannot read $lcov_file: $!\n";

my ($sf, $in_record);
my ($record_da_total, $record_da_hit, $record_ba_total, $record_ba_hit);
my ($total_da, $total_da_hit, $total_ba, $total_ba_hit, $files, $invalid) =
  (0, 0, 0, 0, 0, 0);
my %seen_sf;
my %seen_source;

# SB-COVER emits DA rows for declarations, package forms, and macro expansion
# locations that have no executable instrumentation. Keep this finite list
# audited: a source change must update it rather than silently widening it.
my %non_executable_da = map { $_ => 1 } qw(
  conditions.lisp:3 conditions.lisp:4 conditions.lisp:6 conditions.lisp:7
  conditions.lisp:8 conditions.lisp:9 conditions.lisp:10 conditions.lisp:11
  primitives.lisp:10 primitives.lisp:11 primitives.lisp:12 primitives.lisp:13
  primitives.lisp:36 primitives.lisp:79 primitives.lisp:101 primitives.lisp:139
  fifo.lisp:2 fifo.lisp:3 fifo.lisp:4 fifo.lisp:5 fifo.lisp:6 fifo.lisp:7
  fifo.lisp:8 fifo.lisp:11 fifo.lisp:12 fifo.lisp:13 fifo.lisp:14 fifo.lisp:15
  fifo.lisp:16
  promise.lisp:9 promise.lisp:10 promise.lisp:11 promise.lisp:12 promise.lisp:13
  promise.lisp:14 promise.lisp:15 promise.lisp:17 promise.lisp:18 promise.lisp:19
  promise.lisp:20 promise.lisp:21 promise.lisp:22 promise.lisp:23 promise.lisp:24
  promise.lisp:25 promise.lisp:26 promise.lisp:31 promise.lisp:32 promise.lisp:33
  promise.lisp:34 promise.lisp:35
  channel.lisp:10 channel.lisp:11 channel.lisp:12 channel.lisp:13 channel.lisp:14
  channel.lisp:15 channel.lisp:16 channel.lisp:21 channel.lisp:22 channel.lisp:23
  channel.lisp:24 channel.lisp:25 channel.lisp:26 channel.lisp:20 channel.lisp:27
  channel.lisp:28 channel.lisp:29 channel.lisp:30 channel.lisp:31 channel.lisp:32
  channel.lisp:33 channel.lisp:34 channel.lisp:35 channel.lisp:36 channel.lisp:37
  channel.lisp:38 channel.lisp:39 channel.lisp:40 channel.lisp:41 channel.lisp:43
  channel.lisp:44 channel.lisp:45 channel.lisp:47
  channel.lisp:55 channel.lisp:56 channel.lisp:57 channel.lisp:58
  channel.lisp:61 channel.lisp:62 channel.lisp:63 channel.lisp:64 channel.lisp:65
  channel.lisp:66 channel.lisp:67 channel.lisp:68 channel.lisp:69 channel.lisp:70
  channel.lisp:71 channel.lisp:72 channel.lisp:73 channel.lisp:74 channel.lisp:75
  channel.lisp:76 channel.lisp:77 channel.lisp:78 channel.lisp:79 channel.lisp:80
  channel.lisp:81 channel.lisp:82 channel.lisp:83 channel.lisp:84 channel.lisp:85
  channel.lisp:86 channel.lisp:87 channel.lisp:88 channel.lisp:89 channel.lisp:90
  channel.lisp:91 channel.lisp:92 channel.lisp:93 channel.lisp:94 channel.lisp:95
  channel.lisp:96 channel.lisp:97 channel.lisp:98 channel.lisp:101 channel.lisp:102
  channel.lisp:103
  select.lisp:10 select.lisp:11 select.lisp:12 select.lisp:13 select.lisp:14
  select.lisp:15 select.lisp:16 select.lisp:48 select.lisp:62 select.lisp:68 select.lisp:100
  select.lisp:101 select.lisp:102
  executor.lisp:7 executor.lisp:8 executor.lisp:9 executor.lisp:10 executor.lisp:11
  executor.lisp:12 executor.lisp:13 executor.lisp:20 executor.lisp:21 executor.lisp:22
  executor.lisp:23 executor.lisp:24 executor.lisp:25 executor.lisp:26 executor.lisp:55
  executor.lisp:56 executor.lisp:89 executor.lisp:104 executor.lisp:105 executor.lisp:106
  executor.lisp:107 executor.lisp:108
  scope-state.lisp:2 scope-state.lisp:3 scope-state.lisp:4 scope-state.lisp:5
  scope-state.lisp:6 scope-state.lisp:7 scope-state.lisp:8 scope-state.lisp:10
  scope-state.lisp:11 scope-state.lisp:12 scope-state.lisp:13 scope-state.lisp:14
  scope-state.lisp:15 scope-state.lisp:16 scope-state.lisp:17 scope-state.lisp:18
  scope-execution.lisp:2 scope-execution.lisp:3 scope-execution.lisp:4
  scope-execution.lisp:5 scope-execution.lisp:6 scope-execution.lisp:7 scope-execution.lisp:8
  scope.lisp:12
);
my %seen_non_executable_da;

sub finish_record {
  return unless $in_record;
  if (!defined $sf || $sf eq q{} || !$record_da_total) {
    $invalid = 1;
  } else {
    $total_da += $record_da_total;
    $total_da_hit += $record_da_hit;
    $total_ba += $record_ba_total;
    $total_ba_hit += $record_ba_hit;
    $files++;
  }
  ($sf, $in_record, $record_da_total, $record_da_hit, $record_ba_total, $record_ba_hit) =
    (undef, 0, 0, 0, 0, 0);
}

while (<$lcov>) {
  chomp;
  if (/^SF:(.*)$/) {
    if ($in_record) {
      $invalid = 1;
      finish_record();
    }
    my $source_basename = basename $1;
    $invalid = 1
      if $1 eq q{}
      || $seen_sf{$1}++
      || !$permitted_source{$source_basename}
      || ($expected_source{$source_basename} && $seen_source{$source_basename}++);
    ($sf, $in_record, $record_da_total, $record_da_hit, $record_ba_total, $record_ba_hit) =
      ($1, 1, 0, 0, 0, 0);
  } elsif (/^DA:([0-9]+),([0-9]+)(?:,[^,]+)?$/) {
    unless ($in_record) {
      $invalid = 1;
      next;
    }
    my ($line, $hits) = ($1, $2);
    my ($basename) = $sf =~ m{([^/]+)\z};
    my $location = "$basename:$line";
    if ($non_executable_da{$location}) {
      $seen_non_executable_da{$location} = 1;
      next;
    }
    $record_da_total++ if $in_record;
    $record_da_hit++ if $in_record && $hits > 0;
  } elsif (/^BA:[0-9]+,([0-9]+)$/) {
    $invalid = 1 unless $in_record;
    $record_ba_total++ if $in_record;
    $record_ba_hit++ if $in_record && $1 > 0;
  } elsif (/^(?:DA|BA|LF|LH|BRDA):/) {
    $invalid = 1;
  } elsif (/^end_of_record$/) {
    $invalid = 1 unless $in_record;
    finish_record();
  }
}

$invalid = 1 if $in_record;
die "LCOV parsing failed\n" if $invalid || !$files;
my @missing_sources = sort grep { !$seen_source{$_} } keys %expected_source;
die "LCOV is missing implementation source records: @missing_sources\n"
  if @missing_sources;
my @missing_non_executable_da = sort grep { !$seen_non_executable_da{$_} }
  keys %non_executable_da;
die "SB-COVER exclusion locations disappeared: @missing_non_executable_da\n"
  if @missing_non_executable_da;
die "LCOV reports zero instrumented expressions\n" unless $total_da;
die "LCOV expression coverage is $total_da_hit/$total_da, not 100%\n"
  unless $total_da_hit == $total_da;
die "LCOV branch coverage is $total_ba_hit/$total_ba, not 100%\n"
  if $total_ba && $total_ba_hit != $total_ba;
print "LCOV total expression coverage: $total_da_hit/$total_da (100%)\n";
print "LCOV total branch coverage: $total_ba_hit/$total_ba (100%)\n" if $total_ba;
print "Ignored SB-COVER non-executable DA rows: "
  . scalar(keys %seen_non_executable_da) . "\n";
