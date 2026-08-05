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
  channel-waiters.lisp:39 channel-waiters.lisp:40 channel-waiters.lisp:119
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
  channel.lisp:127 channel.lisp:128 channel.lisp:236
  conditions.lisp:8 conditions.lisp:10 conditions.lisp:11 conditions.lisp:12 conditions.lisp:13
  conditions.lisp:15 conditions.lisp:16 conditions.lisp:17 conditions.lisp:18 conditions.lisp:19
  conditions.lisp:20 conditions.lisp:22 conditions.lisp:23 conditions.lisp:24 conditions.lisp:25
  conditions.lisp:26 conditions.lisp:27 conditions.lisp:28 conditions.lisp:29 conditions.lisp:30
  conditions.lisp:31 conditions.lisp:32 conditions.lisp:33 conditions.lisp:34 conditions.lisp:35
  conditions.lisp:36
  executor-work-queue.lisp:27 executor-work-queue.lisp:31 executor-work-queue.lisp:32 executor-work-queue.lisp:33 executor-work-queue.lisp:34
  executor-work-queue.lisp:35 executor-work-queue.lisp:36 executor-work-queue.lisp:38 executor-work-queue.lisp:39 executor-work-queue.lisp:40
  executor-work-queue.lisp:41 executor-work-queue.lisp:101
  executor.lisp:6 executor.lisp:8 executor.lisp:9 executor.lisp:10 executor.lisp:11
  executor.lisp:12 executor.lisp:13 executor.lisp:17 executor.lisp:18 executor.lisp:19
  executor.lisp:20 executor.lisp:160 executor.lisp:184 executor.lisp:185 executor.lisp:186
  executor.lisp:187 executor.lisp:257
  latch.lisp:11 latch.lisp:16 latch.lisp:17 latch.lisp:18 latch.lisp:19
  latch.lisp:73 latch.lisp:74 latch.lisp:75 latch.lisp:76 latch.lisp:77
  latch.lisp:78 latch.lisp:79 latch.lisp:82
  primitives.lisp:9 primitives.lisp:30 primitives.lisp:38 primitives.lisp:39 primitives.lisp:40
  primitives.lisp:41 primitives.lisp:42 primitives.lisp:43 primitives.lisp:44 primitives.lisp:81
  primitives.lisp:103 primitives.lisp:124 primitives.lisp:125 primitives.lisp:126 primitives.lisp:127
  primitives.lisp:128 primitives.lisp:129 primitives.lisp:130 primitives.lisp:131 primitives.lisp:169
  primitives.lisp:206
  promise-combinators.lisp:16 promise-combinators.lisp:23 promise-combinators.lisp:24 promise-combinators.lisp:25
  promise-racing.lisp:25 promise-racing.lisp:27 promise-racing.lisp:28 promise-racing.lisp:29 promise-racing.lisp:30
  promise-racing.lisp:32 promise-racing.lisp:33 promise-racing.lisp:34 promise-racing.lisp:35 promise-racing.lisp:36
  promise-racing.lisp:37 promise-racing.lisp:38 promise-racing.lisp:39 promise-racing.lisp:40 promise-racing.lisp:42
  promise-racing.lisp:43 promise-racing.lisp:44 promise-racing.lisp:45 promise-racing.lisp:46 promise-racing.lisp:47
  promise-racing.lisp:48 promise-racing.lisp:50 promise-racing.lisp:51 promise-racing.lisp:52 promise-racing.lisp:53
  promise-racing.lisp:54 promise-racing.lisp:55 promise-racing.lisp:56 promise-racing.lisp:57 promise-racing.lisp:58
  promise-racing.lisp:59 promise-racing.lisp:60 promise-racing.lisp:61 promise-racing.lisp:62 promise-racing.lisp:63
  promise-racing.lisp:64 promise-racing.lisp:65 promise-racing.lisp:66 promise-racing.lisp:67 promise-racing.lisp:68
  promise-racing.lisp:69 promise-racing.lisp:70 promise-racing.lisp:71 promise-racing.lisp:72 promise-racing.lisp:73
  promise-racing.lisp:74 promise-racing.lisp:75 promise-racing.lisp:76
  promise.lisp:8 promise.lisp:11 promise.lisp:12 promise.lisp:13 promise.lisp:14
  promise.lisp:15 promise.lisp:16 promise.lisp:21 promise.lisp:22 promise.lisp:208
  scope-execution.lisp:8
  scope-state.lisp:10 scope-state.lisp:13 scope-state.lisp:16 scope-state.lisp:17 scope-state.lisp:20
  scope-state.lisp:28 scope-state.lisp:34 scope-state.lisp:35 scope-state.lisp:37 scope-state.lisp:40
  scope-state.lisp:42 scope-state.lisp:43 scope-state.lisp:44
  scope.lisp:22
  select.lisp:9 select.lisp:12 select.lisp:13 select.lisp:15 select.lisp:16
  select.lisp:17 select.lisp:18 select.lisp:19 select.lisp:20 select.lisp:21
  select.lisp:22 select.lisp:23 select.lisp:24 select.lisp:25 select.lisp:26
  select.lisp:27 select.lisp:28 select.lisp:29 select.lisp:30 select.lisp:31
  select.lisp:32 select.lisp:33 select.lisp:34 select.lisp:35 select.lisp:36
  select.lisp:37 select.lisp:38 select.lisp:39 select.lisp:40 select.lisp:41
  select.lisp:42 select.lisp:43 select.lisp:44 select.lisp:45 select.lisp:46
  select.lisp:47 select.lisp:48 select.lisp:49 select.lisp:50 select.lisp:51
  select.lisp:52 select.lisp:53 select.lisp:54 select.lisp:55 select.lisp:57
  select.lisp:58 select.lisp:59 select.lisp:60 select.lisp:61 select.lisp:62
  select.lisp:63 select.lisp:64 select.lisp:65 select.lisp:66 select.lisp:68
  select.lisp:69 select.lisp:70 select.lisp:71 select.lisp:72 select.lisp:73
  select.lisp:74 select.lisp:75 select.lisp:76 select.lisp:77 select.lisp:78
  select.lisp:79 select.lisp:80 select.lisp:81 select.lisp:82 select.lisp:83
  select.lisp:84 select.lisp:85 select.lisp:86 select.lisp:87 select.lisp:88
  select.lisp:89 select.lisp:90 select.lisp:91 select.lisp:92 select.lisp:93
  select.lisp:94 select.lisp:95 select.lisp:96 select.lisp:97 select.lisp:99
  select.lisp:100 select.lisp:101 select.lisp:102 select.lisp:103 select.lisp:104
  select.lisp:105 select.lisp:106 select.lisp:107 select.lisp:108 select.lisp:109
  select.lisp:110 select.lisp:111 select.lisp:112 select.lisp:113 select.lisp:114
  select.lisp:115 select.lisp:116 select.lisp:117 select.lisp:118 select.lisp:119
  select.lisp:120 select.lisp:121 select.lisp:122 select.lisp:123 select.lisp:124
  select.lisp:125 select.lisp:126 select.lisp:127 select.lisp:128 select.lisp:129
  select.lisp:130 select.lisp:131 select.lisp:132 select.lisp:133 select.lisp:134
  select.lisp:135 select.lisp:136 select.lisp:137 select.lisp:138 select.lisp:139
  select.lisp:140 select.lisp:141 select.lisp:142 select.lisp:143 select.lisp:144
  select.lisp:145 select.lisp:146 select.lisp:147 select.lisp:148 select.lisp:149
  select.lisp:150 select.lisp:151 select.lisp:152 select.lisp:153 select.lisp:154
  select.lisp:155 select.lisp:156 select.lisp:157 select.lisp:188
  stream-fan-in.lisp:16 stream-fan-in.lisp:59 stream-fan-in.lisp:60 stream-fan-in.lisp:61 stream-fan-in.lisp:62
  stream-fan-in.lisp:63 stream-fan-in.lisp:64 stream-fan-in.lisp:65 stream-fan-in.lisp:66 stream-fan-in.lisp:67
  stream-fan-in.lisp:68 stream-fan-in.lisp:69 stream-fan-in.lisp:70 stream-fan-in.lisp:71 stream-fan-in.lisp:72
  stream-fan-in.lisp:73 stream-fan-in.lisp:75 stream-fan-in.lisp:102 stream-fan-in.lisp:120 stream-fan-in.lisp:136
  stream-fan-in.lisp:158 stream-fan-in.lisp:188 stream-fan-in.lisp:220
  stream-fan-out.lisp:8 stream-fan-out.lisp:10 stream-fan-out.lisp:35 stream-fan-out.lisp:55 stream-fan-out.lisp:71
  stream-fan-out.lisp:87
  stream-map-concurrent.lisp:8 stream-map-concurrent.lisp:22 stream-map-concurrent.lisp:23 stream-map-concurrent.lisp:24 stream-map-concurrent.lisp:25
  stream-map-concurrent.lisp:26 stream-map-concurrent.lisp:28 stream-map-concurrent.lisp:29 stream-map-concurrent.lisp:30 stream-map-concurrent.lisp:31
  stream-map-concurrent.lisp:32 stream-map-concurrent.lisp:33 stream-map-concurrent.lisp:34 stream-map-concurrent.lisp:35 stream-map-concurrent.lisp:36
  stream-map-concurrent.lisp:37 stream-map-concurrent.lisp:38 stream-map-concurrent.lisp:39 stream-map-concurrent.lisp:40 stream-map-concurrent.lisp:41
  stream-map-concurrent.lisp:42 stream-map-concurrent.lisp:43 stream-map-concurrent.lisp:44 stream-map-concurrent.lisp:45 stream-map-concurrent.lisp:46
  stream-map-concurrent.lisp:47 stream-map-concurrent.lisp:48 stream-map-concurrent.lisp:49 stream-map-concurrent.lisp:50 stream-map-concurrent.lisp:51
  stream-map-concurrent.lisp:52 stream-map-concurrent.lisp:53 stream-map-concurrent.lisp:54 stream-map-concurrent.lisp:56 stream-map-concurrent.lisp:140
  stream-map-concurrent.lisp:197
  stream-partition.lisp:6 stream-partition.lisp:8
  stream-terminal.lisp:14
  stream.lisp:15 stream.lisp:127 stream.lisp:135 stream.lisp:146 stream.lisp:157
  stream.lisp:166 stream.lisp:185 stream.lisp:246 stream.lisp:256 stream.lisp:278
  timeout.lisp:18

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
