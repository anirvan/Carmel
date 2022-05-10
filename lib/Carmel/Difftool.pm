package Carmel::Difftool;
use strict;
use warnings;

use Carton::Snapshot;
use CPAN::DistnameInfo;
use version;
use Class::Tiny;
use Capture::Tiny qw(capture);
use Path::Tiny;
use List::Util qw(max);

use constant RED => 31;
use constant GREEN => 32;
use constant YELLOW => 33;
use constant PURPLE => 35;

sub color {
    my($code, $text) = @_;
    return $text unless -t STDOUT && !$ENV{NO_COLOR};
    return "\e[${code}m${text}\e[0m";
}

sub load_snapshot {
    my($self, $file, $dists, $index) = @_;

    defined $file
      or die "Usage: carmel difftool LOCAL REMOTE\n";

    my $snapshot = Carton::Snapshot->new(path => $file);
    $snapshot->load;

    for my $dist ($snapshot->distributions) {
        (my $path = $dist->pathname) =~ s!^[A-Z]/[A-Z]{2}/!!;
        my $info = CPAN::DistnameInfo->new($path);
        $dists->{$info->dist}[$index] = $info;
    }
}

sub max_len {
    my @list = @_;
    return max map { defined($_) ? length : 0 } @list;
}

sub diff {
    my($self, @args) = @_;

    my %dists;
    $self->load_snapshot($args[0], \%dists, 0);
    $self->load_snapshot($args[1], \%dists, 1);

    if ($Carmel::DEBUG) {
        $self->text_diff(\%dists);
    } else {
        # compute longest dist name and versions for printing
        my $npad  = max_len keys %dists;
        my $vpadl = max_len map { $_->[0] && $_->[0]->version } values %dists;
        my $vpadr = max_len map { $_->[1] && $_->[1]->version } values %dists;
        for my $dist (sort { lc($a) cmp lc($b) } keys %dists) {
            $self->dist_diff($npad, $vpadl, $vpadr, $dist, @{$dists{$dist}});
        }
    }
}

sub text_diff {
    my($self, $dists) = @_;

    my @text;
    for my $dist (sort { lc($a) cmp lc($b) } keys %$dists) {
        for my $idx (0, 1) {
            if ($dists->{$dist}[$idx]) {
                $text[$idx] .= "$dist\n  " . $dists->{$dist}[$idx]->pathname . "\n";
            }
        }
    }

    $self->try_text_diff(@text)
      or $self->system_diff(@text);
}

sub try_text_diff {
    my($self, @text) = @_;

    return if $ENV{PERL_CARMEL_USE_SYSTEM_DIFF};

    eval { require Text::Diff; 1 }
      or return;

    my $diff = Text::Diff::diff(\$text[0], \$text[1], { FILENAME_A => "a", FILENAME_B => "b" });
    print $self->style_git_diff(split /\n/, $diff);

    return 1;
}

sub system_diff {
    my($self, @text) = @_;

    my @files = map {
        my $temp = Path::Tiny->tempfile;
        $temp->spew($_);
        $temp;
    } @text;

    my($stdout, $stderr, $code) = capture { system("diff", "-u", @files) };
    print $self->style_git_diff(split /\n/, $stdout);
}

sub style_git_diff {
    my($self, @lines) = @_;

    for (@lines) {
        chomp;
        s!^\-\-\- .*?$!color(YELLOW, "--- a/cpanfile.snapshot")!e and next;
        s!^\+\+\+ .*?$!color(YELLOW, "+++ b/cpanfile.snapshot")!e and next;
        s/^([\-\+])(.+)$/color($1 eq '+' ? GREEN : RED, "$1$2")/e and next;
        s/^(\@\@.*?\@\@)$/color(PURPLE, $1)/e;
    }

    return join("\n", @lines, '');
}

sub dist_diff {
    my($self, $npad, $vpadl, $vpadr, $dist, $old, $new) = @_;

    # unchanged
    return if $old && $new && $old->distvname eq $new->distvname;

    my $fmt = "%-${npad}s";
    my $vl = sub { sprintf("%${vpadl}s", $_[0]) };
    my $vr = sub { sprintf("%${vpadr}s", $_[0]) };

    # added
    if (!$old && $new) {
        printf "$fmt  %s  %s\n", $dist,
          $vl->(""),
          color(GREEN, $vr->($new->version));
        return;
    }

    # removed
    if ($old && !$new) {
        printf "$fmt  %s\n", $dist,
          color(RED, $vl->($old->version));
        return;
    }

    printf "$fmt  %s  %s\n", $dist,
      color(RED, $vl->($old->version)),
      color(GREEN, $vr->($new->version));
}

1;
