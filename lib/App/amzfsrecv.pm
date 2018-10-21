package App::amzfsrecv;

our $VERSION = "0.02";

use feature 'say';
use strict;
use warnings;
use Capture::Tiny ':all';
use Cwd 'abs_path';
use JSON;
use Moo;
use MooX::Options protect_argv => 0, usage_string => 'USAGE: %c %o host [disk]';
use Perl6::Slurp;

{
my $order = 1;
my $amanda = 'amanda';
option amanda => (
  is => 'ro', short => 'a', doc => "amanda server: $amanda",
  default => $amanda,
);

my $config = 'DAILY';
option config => (
  is => 'ro', short => 'c', doc => "amanda backup config: $config",
  default => $config,
);

option dryrun => (
  is => 'ro', short => 'd',
);

option exact => (
  is => 'ro', short => 'e', doc => "amadmin find --exact",
);

option datestmp => (
  is => 'ro', short => 'f', doc => "amadmin find --before datestmp (if there were)",
  format => 's',
  order => $order++,
);

my $init_sh = 'init.sh';
option init_sh => (
  is => 'ro', short => 'i', doc => "install freebsd root on zfs: $init_sh",
  default => $init_sh, format => 's@',
  order => $order++,
);

my $twist_sh = 'twist.sh';
option twist_sh => (
  is => 'ro', short => 't', doc => "twist confs: $twist_sh",
  default => $twist_sh, format => 's@',
  order => $order++,
);

option no_sudo => (
  is => 'ro', short => 'S', doc => 'run without sudo',
  order => $order++,
);

my $env = { zroot => 'tank', rootfs => 'tank/ROOT/default' };
option env => (
  is => 'rw', short => 'x', doc => encode_json($env),
  default => sub { $env }, format => 'json',
  order => $order++,
);

option verbose => (
  is => 'rw', short => 'v',
  order => $order++,
);

has host => (is => 'rw');
}

sub _sh {
  my $self = shift;
  say "@_" if $self->verbose;
  my @env = map { join '=', $_, $self->env->{$_} } keys %{$self->env};
  push @env, "no_sudo=yes" if $self->no_sudo;
  ('env', @env, qw/sh -c/, join ' ', @_);
}

sub _sudo {
  my $self = shift;
  $self->no_sudo? @_ : ('sudo', @_);
}

sub sh {
  my ($self, @cmd) = @_;
  my $system = sub {
    my @sh = $self->_sh(@cmd);
    system @sh unless $self->dryrun
  };
  my ($out, $err, $rc) = $self->verbose? tee \&$system : capture \&$system;
  unless (defined wantarray) {
    unless (($rc >> 8) == 0) {
      unless ($self->verbose) {
        say STDERR "@cmd";
        warn $out if $out;
        warn $err if $err;
      }
      $rc >>= 8;
      warn "# exit ", $rc, "\n";
      exit $rc;
    }
  }
  wantarray? ($out, $err, $rc) : $rc;
}

sub amfind {
  my $self = shift;

  my @amfind = (
    'amadmin', $self->config,
    'find', $self->exact? '--exact' : (), $self->host, @_,
  );
  my @amfind_out = slurp '-|', $self->_sh('ssh', $self->amanda, @amfind), { chomp => 1 };
  if (grep /^No dump to list$/, @amfind_out) {
    say STDERR $_ for @amfind_out;
    exit 1;
  }

  my @list;
  my %skip;
  for (reverse @amfind_out) {
    next unless my ($date, $time, @rest) = split /\s+/;
    next if $date eq 'date';
    (my $datestmp = $date.$time) =~ s/[-:]//g;
    next if $self->datestmp && ($datestmp cmp $self->datestmp) > 0;
    my $row = { datestmp => $datestmp };
    $row->{$_} = shift @rest for qw/host path lev tape file part status/;
    $skip{$row->{host}}{$row->{path}}{$_}++ for $row->{lev} + 1 .. 9;
    next if $skip{$row->{host}}{$row->{path}}{$row->{lev}}++;
    unshift @list, $row;
  }

  @list;
}

sub run_script {
  my $self = shift;
  my $script = shift;
  if (ref $script) {
    $self->run_script($_, @_) for @$script;
  } elsif (-f $script) {
    $self->sh(abs_path($script), @_);
  } elsif ($script) {
    say "# $script: $!";
  }
}

sub amzfsrecv {
  my $self = shift;

  my $destroy_snapshot;
  if (@_) {
    $destroy_snapshot = 1;
  } else {
    $self->run_script($self->init_sh);
  }

  my @amfind = $self->amfind(@_);
  for (@amfind) {
    my @opts = (qw/-du/);
    if ($_->{lev} == 0) {
      if ($destroy_snapshot) {
        $self->sh(
          qw/zfs list -H -t snapshot/,
          "|", "grep", '^'.join('/', '$zroot', $_->{path} =~ /\/(.*)/).'@',
          "|", qw/cut -wf1/,
          "|", qw/xargs -n1/, $self->_sudo, qw/zfs destroy -r/,
        );
      }
      push @opts, '-F';
    }
    if ($self->verbose) {
      push @opts, '-v';
    }
    $self->sh(
      'ssh', $self->amanda, qw/amfetchdump -a -p --exact-match/,
      $self->config, $self->host, $_->{path}, $_->{datestmp}, $_->{lev},
      '|', $self->_sudo, qw/zfs recv/, @opts, '$zroot',
    );
    my $path = join '/', '$zroot', $_->{path} =~ /\/(.*)/;
    (my $snap = 'amanda-' . $_->{path}) =~ s/\//_/g;
    $self->sh($self->_sudo, qw/zfs rename/, map "$path\@$snap-$_", 'current', $_->{lev});
  }
}

sub run {
  my $self = shift->new_with_options;
  $self->options_usage(1) unless $self->host || @ARGV > 0;
  if ($self->dryrun) {
    $self->verbose(1);
    say "# dryrun";
    say for map {(my $v = $self->env->{$_}) =~ s/["]/\\$&/g; "$_=\"$v\""} keys %{$self->env};
  }
  $self->host(shift @ARGV) unless $self->host;
  $self->amzfsrecv(@ARGV);
  $self->run_script($self->twist_sh);
  say "# all done" if $self->verbose;
  0;
}

1;
__END__

=encoding utf-8

=head1 NAME

App::amzfsrecv - amfetchdump -p and zfs recv

=head1 SYNOPSIS

    use App::amzfsrecv;
    App::amzfsrecv->run;

=head1 DESCRIPTION

App::amzfsrecv is ...

=head1 LICENSE

Copyright (C) KUBO, Koichi.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

KUBO, Koichi E<lt>k@obuk.orgE<gt>

=cut

