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
  conditions.lisp:8 conditions.lisp:10 conditions.lisp:11 conditions.lisp:12 conditions.lisp:13
  conditions.lisp:15 conditions.lisp:16 conditions.lisp:17 conditions.lisp:18 conditions.lisp:19
  conditions.lisp:20 conditions.lisp:22 conditions.lisp:23 conditions.lisp:24 conditions.lisp:25
  conditions.lisp:26 conditions.lisp:27 conditions.lisp:28 conditions.lisp:29 conditions.lisp:30
  conditions.lisp:31 conditions.lisp:32 conditions.lisp:33 conditions.lisp:34 conditions.lisp:35
  conditions.lisp:36
  primitives.lisp:9 primitives.lisp:30 primitives.lisp:73 primitives.lisp:95 primitives.lisp:141
  fifo.lisp:12 fifo.lisp:15 fifo.lisp:16 fifo.lisp:17 fifo.lisp:18
  fifo.lisp:21 fifo.lisp:22
  promise.lisp:8 promise.lisp:11 promise.lisp:12 promise.lisp:13 promise.lisp:14
  promise.lisp:15 promise.lisp:16 promise.lisp:21 promise.lisp:22
  promise-combinators.lisp:9 promise-combinators.lisp:16 promise-combinators.lisp:17 promise-combinators.lisp:18
  channel.lisp:9 channel.lisp:12 channel.lisp:13 channel.lisp:14 channel.lisp:15
  channel.lisp:16 channel.lisp:17 channel.lisp:18 channel.lisp:19 channel.lisp:20
  channel.lisp:21 channel.lisp:22 channel.lisp:25 channel.lisp:26 channel.lisp:27
  channel.lisp:28 channel.lisp:34 channel.lisp:35 channel.lisp:41 channel.lisp:42
  channel.lisp:44 channel.lisp:45 channel.lisp:46 channel.lisp:48 channel.lisp:49
  channel.lisp:50 channel.lisp:51 channel.lisp:53 channel.lisp:60 channel.lisp:61
  channel.lisp:62 channel.lisp:63 channel.lisp:65 channel.lisp:66 channel.lisp:67
  channel.lisp:68 channel.lisp:69 channel.lisp:70 channel.lisp:71 channel.lisp:72
  channel.lisp:73 channel.lisp:74 channel.lisp:75 channel.lisp:76 channel.lisp:77
  channel.lisp:78 channel.lisp:79 channel.lisp:80 channel.lisp:81 channel.lisp:82
  channel.lisp:83 channel.lisp:84 channel.lisp:85 channel.lisp:86 channel.lisp:87
  channel.lisp:88 channel.lisp:89 channel.lisp:90 channel.lisp:91 channel.lisp:92
  channel.lisp:93 channel.lisp:94 channel.lisp:95 channel.lisp:96 channel.lisp:97
  select.lisp:9 select.lisp:12 select.lisp:13 select.lisp:14 select.lisp:15
  select.lisp:16 select.lisp:17 select.lisp:18 select.lisp:19 select.lisp:20
  select.lisp:21 select.lisp:22 select.lisp:23 select.lisp:24 select.lisp:25
  select.lisp:26 select.lisp:27 select.lisp:28 select.lisp:29 select.lisp:30
  select.lisp:31 select.lisp:32 select.lisp:33 select.lisp:34 select.lisp:35
  select.lisp:36 select.lisp:37 select.lisp:38 select.lisp:39 select.lisp:40
  select.lisp:41 select.lisp:42 select.lisp:43 select.lisp:44 select.lisp:45
  select.lisp:46 select.lisp:47 select.lisp:48 select.lisp:49 select.lisp:50
  select.lisp:51 select.lisp:52 select.lisp:53 select.lisp:54 select.lisp:55
  select.lisp:56 select.lisp:57 select.lisp:58 select.lisp:59 select.lisp:60
  select.lisp:61 select.lisp:62 select.lisp:63 select.lisp:64 select.lisp:65
  select.lisp:66 select.lisp:67 select.lisp:68 select.lisp:69 select.lisp:70
  select.lisp:71 select.lisp:72 select.lisp:73 select.lisp:74 select.lisp:75
  select.lisp:76 select.lisp:77 select.lisp:78 select.lisp:79 select.lisp:80
  select.lisp:81 select.lisp:82 select.lisp:83 select.lisp:84 select.lisp:85
  select.lisp:86 select.lisp:87 select.lisp:88 select.lisp:89 select.lisp:90
  select.lisp:91 select.lisp:92 select.lisp:93 select.lisp:94 select.lisp:95
  select.lisp:96 select.lisp:97 select.lisp:98 select.lisp:99 select.lisp:100
  select.lisp:101 select.lisp:102 select.lisp:103 select.lisp:104 select.lisp:105
  select.lisp:106 select.lisp:107 select.lisp:108 select.lisp:109 select.lisp:110
  select.lisp:111 select.lisp:112 select.lisp:113 select.lisp:114 select.lisp:115
  select.lisp:116 select.lisp:117 select.lisp:118 select.lisp:119 select.lisp:120
  select.lisp:121 select.lisp:122 select.lisp:123 select.lisp:124
  executor.lisp:6 executor.lisp:14 executor.lisp:15 executor.lisp:16 executor.lisp:17
  executor.lisp:18 executor.lisp:20 executor.lisp:21 executor.lisp:22 executor.lisp:44
  executor.lisp:45 executor.lisp:46 executor.lisp:47 executor.lisp:94 executor.lisp:113
  executor.lisp:114 executor.lisp:115 executor.lisp:116
  scope-state.lisp:10 scope-state.lisp:13 scope-state.lisp:16 scope-state.lisp:17 scope-state.lisp:20
  scope-state.lisp:26 scope-state.lisp:27 scope-state.lisp:29 scope-state.lisp:32 scope-state.lisp:34
  scope-state.lisp:35 scope-state.lisp:36
  scope-execution.lisp:8
  scope.lisp:14
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
