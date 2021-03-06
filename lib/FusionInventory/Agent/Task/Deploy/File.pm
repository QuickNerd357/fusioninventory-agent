package FusionInventory::Agent::Task::Deploy::File;

use strict;
use warnings;

use Digest::SHA;
use English qw(-no_match_vars);
use File::Basename;
use File::Path qw(mkpath);
use File::Glob;
use HTTP::Request;

sub new {
    my ($class, %params) = @_;

    die "no datastore parameter" unless $params{datastore};
    die "no sha512 parameter" unless $params{sha512};

    my $self = {
        p2p                => $params{data}->{p2p},
        retention_duration => $params{data}->{'p2p-retention-duration'} || 60 * 24 * 3,
        uncompress         => $params{data}->{uncompress},
        mirrors            => $params{data}->{mirrors},
        multiparts         => $params{data}->{multiparts},
        name               => $params{data}->{name},
        sha512             => $params{sha512},
        datastore          => $params{datastore},
        client             => $params{client},
        logger             => $params{logger}
    };

    bless $self, $class;

    return $self;
}

sub getPartFilePath {
    my ($self, $sha512) = @_;

    return unless $sha512 =~ /^(.)(.)(.{6})/;
    my $subFilePath = $1.'/'.$2.'/'.$3;

    my @storageDirs =
        File::Glob::bsd_glob($self->{datastore}->{path}.'/fileparts/shared/*'),
        File::Glob::bsd_glob($self->{datastore}->{path}.'/fileparts/private/*');

    foreach my $dir (@storageDirs) {
        if (-f $dir.'/'.$subFilePath) {
            return $dir.'/'.$subFilePath;
        }
    }

    my $filePath = $self->{datastore}->{path}.'/fileparts/';
# filepart not found
    if ($self->{p2p}) {
        $filePath .= 'shared/';
    } else {
        $filePath .= 'private/';
    }

# Compute a directory name that will be used to know
# if the file must be purge. We don't want a new directory
# everytime, so we use a one minute time frame to follow the retention duration unit
    my $expiration    = time + (($self->{retention_duration}+1) * 60);
    my $retentiontime = $expiration - $expiration % 60 ;
    $filePath .= $retentiontime . '/' . $subFilePath;

    return $filePath;
}

sub download {
    my ($self) = @_;

    die unless $self->{mirrors};

    my @peers;
    if ($self->{p2p}) {
        FusionInventory::Agent::Task::Deploy::P2P->require();
        if ($EVAL_ERROR) {
            $self->{logger}->debug("can't enable P2P: $EVAL_ERROR")
        } else {
            my $p2p = FusionInventory::Agent::Task::Deploy::P2P->new(
                scan_timeout    => 1,
                datastore       => $self->{datastore},
                logger          => $self->{logger}
            );
            eval {
                @peers = $p2p->findPeers(62354);
                $self->{p2pnet} = $p2p;
            };
            $self->{logger}->debug("failed to enable P2P: $EVAL_ERROR")
                if $EVAL_ERROR;
        }
    };

    my $lastPeer;
    my $nextPathUpdate = _getNextPathUpdateTime();
    PART: foreach my $sha512 (@{$self->{multiparts}}) {
        my $path = $self->getPartFilePath($sha512);
        if (-f $path) {
            next PART if $self->_getSha512ByFile($path) eq $sha512;
        }
        File::Path::mkpath(dirname($path));

        # try to download from the same peer as last part, if defined
        if ($lastPeer) {
            my $success = $self->_downloadPeer($lastPeer, $sha512, $path);
            next PART if $success;
        }

        # try to download from peers
        foreach my $peer (@peers) {
            my $success = $self->_downloadPeer($peer, $sha512, $path);
            if ($success) {
                $lastPeer = $peer;
                next PART;
            }
            # Update filepath so retention is kept in the future on long search
            if ( time - $nextPathUpdate > 0 ) {
                $path = $self->getPartFilePath($sha512);
                $nextPathUpdate = _getNextPathUpdateTime();
            }
        }

        # try to download from mirrors
        foreach my $mirror (@{$self->{mirrors}}) {
            my $success = $self->_download($mirror, $sha512, $path);
            next PART if $success;
            # Update filepath so retention is kept in the future on long search
            if ( time - $nextPathUpdate > 0 ) {
                $path = $self->getPartFilePath($sha512);
                $nextPathUpdate = _getNextPathUpdateTime();
            }
        }
    }
}

sub _getNextPathUpdateTime {
    my $time = time;
    return $time + 60 - $time % 60;
}

sub _downloadPeer {
    my ($self, $peer, $sha512, $path) = @_;

    my $source = 'http://'.$peer.':62354/deploy/getFile/';

    return $self->_download($source, $sha512, $path, $peer);
}

sub _download {
    my ($self, $source, $sha512, $path, $peer) = @_;

    return unless $sha512 =~ /^(.)(.)/;
    my $sha512dir = $1.'/'.$1.$2.'/';

    my $url = $source.$sha512dir.$sha512;
    $self->{logger}->debug($url);

    my $request = HTTP::Request->new(GET => $url);
    # We want to try direct download without proxy if peer if defined and then
    # we also prefer to use really short timeout to disqualify busy peers and
    # also avoid to block for not responding peers while using P2P
    my $timeout = $peer ? 1 : 180 ;
    my $response = $self->{client}->request($request, $path, $peer, $timeout);

    if ($response->code != 200) {
        if ($response->code != 404 || $response->status_line() =~ /Nothing found/) {
            $self->{logger}->debug2("Remote peer $peer is useless, we should forget it out for a while");
            $self->{p2pnet}->forgetPeer($peer) if $self->{p2pnet};
        }
        return;
    }
    return if ! -f $path;

    if ($self->_getSha512ByFile($path) ne $sha512) {
        $self->{logger}->debug("sha512 failure: $sha512");
        unlink($path);
        return;
    }

    return 1;
}

sub filePartsExists {
    my ($self) = @_;

    foreach my $sha512 (@{$self->{multiparts}}) {

        my $filePath  = $self->getPartFilePath($sha512);
        return 0 unless -f $filePath;

    }
    return 1;
}

sub _getSha512ByFile {
    my ($self, $filePath) = @_;

    my $sha = Digest::SHA->new('512');

    my $sha512;
    eval {
        $sha->addfile($filePath, 'b');
        $sha512 = $sha->hexdigest;
    };
    $self->{logger}->debug("SHA512 failure: $@") if $@;

    return $sha512;
}

sub validateFileByPath {
    my ($self, $filePath) = @_;


    if (-f $filePath) {
        if ($self->_getSha512ByFile($filePath) eq $self->{sha512}) {
            return 1;
        }
    }

    return 0;
}


1;
