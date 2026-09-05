use v5.34;
use File::Basename qw(basename);

my ($lcov_file, $source_root) = @ARGV;
die "Usage: verify-lcov.pl LCOV-FILE SOURCE-ROOT\n"
  unless defined $lcov_file && defined $source_root && @ARGV == 2;

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
    conditions.lisp:5 conditions.lisp:7 conditions.lisp:8 conditions.lisp:9 conditions.lisp:10
    conditions.lisp:12 conditions.lisp:13 conditions.lisp:14 conditions.lisp:15 conditions.lisp:16
    conditions.lisp:17 conditions.lisp:19 conditions.lisp:20 conditions.lisp:21 conditions.lisp:22
    conditions.lisp:23 conditions.lisp:24 conditions.lisp:25 conditions.lisp:26 conditions.lisp:27
    conditions.lisp:28 conditions.lisp:29 conditions.lisp:30 conditions.lisp:31 conditions.lisp:32
    conditions.lisp:33 primitives.lisp:6 primitives.lisp:27 primitives.lisp:35 primitives.lisp:36
    primitives.lisp:37 primitives.lisp:38 primitives.lisp:39 primitives.lisp:40 primitives.lisp:41
    primitives.lisp:78 primitives.lisp:100 primitives.lisp:121 primitives.lisp:122 primitives.lisp:123
    primitives.lisp:124 primitives.lisp:125 primitives.lisp:126 primitives.lisp:127 primitives.lisp:128
    primitives.lisp:166 primitives.lisp:203 timeout.lisp:18 promise.lisp:5 promise.lisp:8
    promise.lisp:9 promise.lisp:10 promise.lisp:11 promise.lisp:12 promise.lisp:13
    promise.lisp:18 promise.lisp:19 promise.lisp:205 promise-combinators.lisp:7 promise-combinators.lisp:14
    promise-combinators.lisp:15 promise-combinators.lisp:16 promise-racing.lisp:5 promise-racing.lisp:7 promise-racing.lisp:8
    promise-racing.lisp:9 promise-racing.lisp:10 promise-racing.lisp:12 promise-racing.lisp:13 promise-racing.lisp:14
    promise-racing.lisp:15 promise-racing.lisp:16 promise-racing.lisp:17 promise-racing.lisp:18 promise-racing.lisp:19
    promise-racing.lisp:20 promise-racing.lisp:22 promise-racing.lisp:23 promise-racing.lisp:24 promise-racing.lisp:25
    promise-racing.lisp:26 promise-racing.lisp:27 promise-racing.lisp:28 promise-racing.lisp:30 promise-racing.lisp:31
    promise-racing.lisp:32 promise-racing.lisp:33 promise-racing.lisp:34 promise-racing.lisp:35 promise-racing.lisp:36
    promise-racing.lisp:37 promise-racing.lisp:38 promise-racing.lisp:39 promise-racing.lisp:40 promise-racing.lisp:41
    promise-racing.lisp:42 promise-racing.lisp:43 promise-racing.lisp:44 promise-racing.lisp:45 promise-racing.lisp:46
    promise-racing.lisp:47 promise-racing.lisp:48 promise-racing.lisp:49 promise-racing.lisp:50 promise-racing.lisp:51
    promise-racing.lisp:52 promise-racing.lisp:53 promise-racing.lisp:54 promise-racing.lisp:55 promise-racing.lisp:56
    channel.lisp:10 channel.lisp:11 channel.lisp:12 channel.lisp:13 channel.lisp:14
    channel.lisp:17 channel.lisp:18 channel.lisp:19 channel.lisp:20 channel.lisp:21
    channel.lisp:22 channel.lisp:23 channel.lisp:24 channel.lisp:25 channel.lisp:26
    channel.lisp:27 channel.lisp:28 channel.lisp:29 channel.lisp:30 channel.lisp:31
    channel.lisp:32 channel.lisp:33 channel.lisp:34 channel.lisp:35 channel.lisp:36
    channel.lisp:37 channel.lisp:38 channel.lisp:39 channel.lisp:40 channel.lisp:41
    channel.lisp:42 channel.lisp:48 channel.lisp:49 channel.lisp:50 channel.lisp:77
    channel.lisp:98 channel.lisp:100 channel.lisp:102 channel.lisp:104 channel.lisp:106
    channel.lisp:107 channel.lisp:108 channel.lisp:109 channel.lisp:110 channel.lisp:111
    channel.lisp:112 channel.lisp:113 channel.lisp:114 channel.lisp:115 channel.lisp:116
    channel.lisp:117 channel.lisp:118 channel.lisp:119 channel.lisp:120 channel.lisp:121
    channel.lisp:122 channel.lisp:123 channel.lisp:124 channel.lisp:125 channel.lisp:126
    channel.lisp:127 channel.lisp:128 channel.lisp:236 channel-waiters.lisp:39 channel-waiters.lisp:40
    channel-waiters.lisp:119 select.lisp:6 select.lisp:9 select.lisp:10 select.lisp:12
    select.lisp:13 select.lisp:14 select.lisp:15 select.lisp:16 select.lisp:17
    select.lisp:18 select.lisp:19 select.lisp:20 select.lisp:21 select.lisp:22
    select.lisp:23 select.lisp:24 select.lisp:25 select.lisp:26 select.lisp:27
    select.lisp:28 select.lisp:29 select.lisp:30 select.lisp:31 select.lisp:32
    select.lisp:33 select.lisp:34 select.lisp:35 select.lisp:36 select.lisp:37
    select.lisp:38 select.lisp:39 select.lisp:40 select.lisp:41 select.lisp:42
    select.lisp:43 select.lisp:44 select.lisp:45 select.lisp:46 select.lisp:47
    select.lisp:48 select.lisp:49 select.lisp:50 select.lisp:51 select.lisp:52
    select.lisp:54 select.lisp:55 select.lisp:56 select.lisp:57 select.lisp:58
    select.lisp:59 select.lisp:60 select.lisp:61 select.lisp:62 select.lisp:63
    select.lisp:65 select.lisp:66 select.lisp:67 select.lisp:68 select.lisp:69
    select.lisp:70 select.lisp:71 select.lisp:72 select.lisp:73 select.lisp:74
    select.lisp:75 select.lisp:76 select.lisp:77 select.lisp:78 select.lisp:79
    select.lisp:80 select.lisp:81 select.lisp:82 select.lisp:83 select.lisp:84
    select.lisp:85 select.lisp:86 select.lisp:87 select.lisp:88 select.lisp:89
    select.lisp:90 select.lisp:91 select.lisp:92 select.lisp:93 select.lisp:94
    select.lisp:96 select.lisp:97 select.lisp:98 select.lisp:99 select.lisp:100
    select.lisp:101 select.lisp:102 select.lisp:103 select.lisp:104 select.lisp:105
    select.lisp:106 select.lisp:107 select.lisp:108 select.lisp:109 select.lisp:110
    select.lisp:111 select.lisp:112 select.lisp:113 select.lisp:114 select.lisp:115
    select.lisp:116 select.lisp:117 select.lisp:118 select.lisp:119 select.lisp:120
    select.lisp:121 select.lisp:122 select.lisp:123 select.lisp:124 select.lisp:125
    select.lisp:126 select.lisp:127 select.lisp:128 select.lisp:129 select.lisp:130
    select.lisp:131 select.lisp:132 select.lisp:133 select.lisp:134 select.lisp:135
    select.lisp:136 select.lisp:137 select.lisp:138 select.lisp:139 select.lisp:140
    select.lisp:141 select.lisp:142 select.lisp:143 select.lisp:144 select.lisp:145
    select.lisp:146 select.lisp:147 select.lisp:148 select.lisp:149 select.lisp:150
    select.lisp:151 select.lisp:152 select.lisp:153 select.lisp:154 select.lisp:185
    executor-work-queue.lisp:6 executor-work-queue.lisp:10 executor-work-queue.lisp:11 executor-work-queue.lisp:12 executor-work-queue.lisp:13
    executor-work-queue.lisp:14 executor-work-queue.lisp:15 executor-work-queue.lisp:17 executor-work-queue.lisp:18 executor-work-queue.lisp:19
    executor-work-queue.lisp:20 executor-work-queue.lisp:80 executor.lisp:5 executor.lisp:7 executor.lisp:8
    executor.lisp:9 executor.lisp:10 executor.lisp:11 executor.lisp:12 executor.lisp:16
    executor.lisp:17 executor.lisp:18 executor.lisp:19 executor.lisp:159 executor.lisp:183
    executor.lisp:184 executor.lisp:185 executor.lisp:186 executor.lisp:256 scope-state.lisp:5
    scope-state.lisp:8 scope-state.lisp:11 scope-state.lisp:12 scope-state.lisp:15 scope-state.lisp:23
    scope-state.lisp:29 scope-state.lisp:30 scope-state.lisp:32 scope-state.lisp:35 scope-state.lisp:37
    scope-state.lisp:38 scope-state.lisp:39 scope-execution.lisp:8 scope.lisp:5 latch.lisp:5
    latch.lisp:10 latch.lisp:11 latch.lisp:12 latch.lisp:13 latch.lisp:67
    latch.lisp:68 latch.lisp:69 latch.lisp:70 latch.lisp:71 latch.lisp:72
    latch.lisp:73 latch.lisp:76 stream.lisp:7 stream.lisp:119 stream.lisp:127
    stream.lisp:138 stream.lisp:149 stream.lisp:158 stream.lisp:177 stream.lisp:238
    stream.lisp:248 stream.lisp:270 stream-terminal.lisp:5 stream-fan-out.lisp:8 stream-fan-out.lisp:10
    stream-fan-out.lisp:35 stream-fan-out.lisp:55 stream-fan-out.lisp:71 stream-fan-out.lisp:87 stream-fan-in.lisp:5
    stream-fan-in.lisp:48 stream-fan-in.lisp:49 stream-fan-in.lisp:50 stream-fan-in.lisp:51 stream-fan-in.lisp:52
    stream-fan-in.lisp:53 stream-fan-in.lisp:54 stream-fan-in.lisp:55 stream-fan-in.lisp:56 stream-fan-in.lisp:57
    stream-fan-in.lisp:58 stream-fan-in.lisp:59 stream-fan-in.lisp:60 stream-fan-in.lisp:61 stream-fan-in.lisp:62
    stream-fan-in.lisp:64 stream-fan-in.lisp:91 stream-fan-in.lisp:109 stream-fan-in.lisp:125 stream-fan-in.lisp:147
    stream-fan-in.lisp:177 stream-fan-in.lisp:209 stream-map-concurrent.lisp:8 stream-map-concurrent.lisp:22 stream-map-concurrent.lisp:23
    stream-map-concurrent.lisp:24 stream-map-concurrent.lisp:25 stream-map-concurrent.lisp:26 stream-map-concurrent.lisp:28 stream-map-concurrent.lisp:29
    stream-map-concurrent.lisp:30 stream-map-concurrent.lisp:31 stream-map-concurrent.lisp:32 stream-map-concurrent.lisp:33 stream-map-concurrent.lisp:34
    stream-map-concurrent.lisp:35 stream-map-concurrent.lisp:36 stream-map-concurrent.lisp:37 stream-map-concurrent.lisp:38 stream-map-concurrent.lisp:39
    stream-map-concurrent.lisp:40 stream-map-concurrent.lisp:41 stream-map-concurrent.lisp:42 stream-map-concurrent.lisp:43 stream-map-concurrent.lisp:44
    stream-map-concurrent.lisp:45 stream-map-concurrent.lisp:46 stream-map-concurrent.lisp:47 stream-map-concurrent.lisp:48 stream-map-concurrent.lisp:49
    stream-map-concurrent.lisp:50 stream-map-concurrent.lisp:51 stream-map-concurrent.lisp:52 stream-map-concurrent.lisp:53 stream-map-concurrent.lisp:54
    stream-map-concurrent.lisp:56 stream-map-concurrent.lisp:140 stream-map-concurrent.lisp:197 stream-partition.lisp:6 stream-partition.lisp:8
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
