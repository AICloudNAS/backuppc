#============================================================= -*-perl-*-
#
# Rsync package
#
# DESCRIPTION
#
# AUTHOR
#   Craig Barratt  <cbarratt@users.sourceforge.net>
#
# COPYRIGHT
#   Copyright (C) 2002  Craig Barratt
#
#========================================================================
#
# Version 1.6.0_CVS, released 10 Dec 2002.
#
# See http://backuppc.sourceforge.net.
#
#========================================================================

package BackupPC::Xfer::RsyncFileIO;

use strict;
use File::Path;
use BackupPC::Attrib qw(:all);
use BackupPC::FileZIO;
use BackupPC::PoolWrite;
use Data::Dumper;

use constant S_IFMT       => 0170000;	# type of file
use constant S_IFDIR      => 0040000; 	# directory
use constant S_IFCHR      => 0020000; 	# character special
use constant S_IFBLK      => 0060000; 	# block special
use constant S_IFREG      => 0100000; 	# regular
use constant S_IFLNK      => 0120000; 	# symbolic link
use constant S_IFSOCK     => 0140000; 	# socket
use constant S_IFIFO      => 0010000; 	# fifo

use vars qw( $RsyncLibOK );

BEGIN {
    eval "use File::RsyncP::Digest";
    if ( $@ ) {
        #
        # Rsync module doesn't exist.
        #
        $RsyncLibOK = 0;
    } else {
        $RsyncLibOK = 1;
    }
};

sub new
{
    my($class, $options) = @_;

    return if ( !$RsyncLibOK );
    $options ||= {};
    my $fio = bless {
        blockSize    => 700,
        logLevel     => 0,
        digest       => File::RsyncP::Digest->new,
        checksumSeed => 0,
	attrib	     => {},
	%$options,
    }, $class;

    $fio->{shareM}   = $fio->{bpc}->fileNameEltMangle($fio->{xfer}{shareName});
    $fio->{outDir}   = "$fio->{xfer}{outDir}/new/";
    $fio->{outDirSh} = "$fio->{outDir}/$fio->{shareM}/";
    $fio->{view}     = BackupPC::View->new($fio->{bpc}, $fio->{host},
					 $fio->{backups});
    $fio->{full} = $fio->{xfer}{type} eq "full" ? 1 : 0;
    $fio->{newFilesFH} = $fio->{xfer}{newFilesFH};
    $fio->{lastBkupNum} = $fio->{xfer}{lastBkupNum};
    return $fio;
}

sub blockSize
{
    my($fio, $value) = @_;

    $fio->{blockSize} = $value if ( defined($value) );
    return $fio->{blockSize};
}

#
# Setup rsync checksum computation for the given file.
#
sub csumStart
{
    my($fio, $f) = @_;
    my $attr = $fio->attribGet($f);

    $fio->{file} = $f;
    $fio->csumEnd if ( defined($fio->{fh}) );
    return if ( $attr->{type} != BPC_FTYPE_FILE );
    if ( !defined($fio->{fh} = BackupPC::FileZIO->open($attr->{fullPath},
						       0,
						       $attr->{compress})) ) {
        $fio->log("Can't open $attr->{fullPath}");
        return -1;
    }
}

sub csumGet
{
    my($fio, $num, $csumLen, $blockSize) = @_;
    my($fileData);

    $num     ||= 100;
    $csumLen ||= 16;

    return if ( !defined($fio->{fh}) );
    if ( $fio->{fh}->read(\$fileData, $blockSize * $num) <= 0 ) {
        return $fio->csumEnd;
    }
    #$fileData = substr($fileData, 0, $blockSize * $num - 2);
    $fio->log(sprintf("%s: getting csum ($num,$csumLen,%d,0x%x)\n",
                            $fio->{file}{name},
                            length($fileData),
                            $fio->{checksumSeed}))
                if ( $fio->{logLevel} >= 10 );
    return $fio->{digest}->rsyncChecksum($fileData, $blockSize,
                                         $csumLen, $fio->{checksumSeed});
}

sub csumEnd
{
    my($fio) = @_;

    return if ( !defined($fio->{fh}) );
    $fio->{fh}->close();
    delete($fio->{fh});
}

sub readStart
{
    my($fio, $f) = @_;
    my $attr = $fio->attribGet($f);

    $fio->{file} = $f;
    $fio->readEnd if ( defined($fio->{fh}) );
    if ( !defined(my $fh = BackupPC::FileZIO->open($attr->{fullPath},
                                           0,
                                           $attr->{compress})) ) {
        $fio->log("Can't open $attr->{fullPath}");
        return;
    }
}

sub read
{
    my($fio, $num) = @_;
    my($fileData);

    $num ||= 32768;
    return if ( !defined($fio->{fh}) );
    if ( $fio->{fh}->read(\$fileData, $num) <= 0 ) {
        return $fio->readEnd;
    }
    return \$fileData;
}

sub readEnd
{
    my($fio) = @_;

    return if ( !defined($fio->{fh}) );
    $fio->{fh}->close;
    delete($fio->{fh});
}

sub checksumSeed
{
    my($fio, $checksumSeed) = @_;

    $fio->{checksumSeed} = $checksumSeed;
}

sub dirs
{
    my($fio, $localDir, $remoteDir) = @_;

    $fio->{localDir}  = $localDir;
    $fio->{remoteDir} = $remoteDir;
}

sub viewCacheDir
{
    my($fio, $share, $dir) = @_;
    my $shareM;

    #$fio->log("viewCacheDir($share, $dir)");
    if ( !defined($share) ) {
	$share  = $fio->{xfer}{shareName};
	$shareM = $fio->{shareM};
    } else {
	$shareM = $fio->{bpc}->fileNameEltMangle($share);
    }
    $shareM = "$shareM/$dir" if ( $dir ne "" );
    return if ( defined($fio->{viewCache}{$shareM}) );
    #
    # purge old cache entries (ie: those that don't match the
    # first part of $dir).
    #
    foreach my $d ( keys(%{$fio->{viewCache}}) ) {
	delete($fio->{viewCache}{$d}) if ( $shareM !~ m{^\Q$d/} );
    }
    #
    # fetch new directory attributes
    #
    $fio->{viewCache}{$shareM}
		= $fio->{view}->dirAttrib($fio->{lastBkupNum}, $share, $dir);
}

sub attribGet
{
    my($fio, $f) = @_;
    my($dir, $fname, $share, $shareM);

    if ( $f->{name} =~ m{(.*)/(.*)} ) {
	$shareM = $fio->{shareM};
	$dir = $1;
	$fname = $2;
    } elsif ( $f->{name} ne "." ) {
	$shareM = $fio->{shareM};
	$dir = "";
	$fname = $f->{name};
    } else {
	$share = "";
	$shareM = "";
	$dir = "";
	$fname = $fio->{xfer}{shareName};
    }
    $fio->viewCacheDir($share, $dir);
    $shareM .= "/$dir" if ( $dir ne "" );
    return $fio->{viewCache}{$shareM}{$fname};
}

sub mode2type
{
    my($fio, $mode) = @_;

    if ( ($mode & S_IFMT) == S_IFREG ) {
	return BPC_FTYPE_FILE;
    } elsif ( ($mode & S_IFMT) == S_IFDIR ) {
	return BPC_FTYPE_DIR;
    } elsif ( ($mode & S_IFMT) == S_IFLNK ) {
	return BPC_FTYPE_SYMLINK;
    } elsif ( ($mode & S_IFMT) == S_IFCHR ) {
	return BPC_FTYPE_CHARDEV;
    } elsif ( ($mode & S_IFMT) == S_IFBLK ) {
	return BPC_FTYPE_BLOCKDEV;
    } elsif ( ($mode & S_IFMT) == S_IFIFO ) {
	return BPC_FTYPE_FIFO;
    } elsif ( ($mode & S_IFMT) == S_IFSOCK ) {
	return BPC_FTYPE_SOCKET;
    } else {
	return BPC_FTYPE_UNKNOWN;
    }
}

#
# Set the attributes for a file.  Returns non-zero on error.
#
sub attribSet
{
    my($fio, $f, $placeHolder) = @_;
    my($dir, $file);

    if ( $f->{name} =~ m{(.*)/(.*)} ) {
	$file = $2;
	$dir  = "$fio->{shareM}/" . $1;
    } elsif ( $f->{name} eq "." ) {
	$dir  = "";
	$file = $fio->{xfer}{shareName};
    } else {
	$dir  = $fio->{shareM};
	$file = $f->{name};
    }

    if ( !defined($fio->{attribLastDir}) || $fio->{attribLastDir} ne $dir ) {
        #
        # Flush any directories that don't match the first part
        # of the new directory
        #
        foreach my $d ( keys(%{$fio->{attrib}}) ) {
            next if ( $d eq "" || "$dir/" =~ m{^\Q$d/} );
            $fio->attribWrite($d);
        }
	$fio->{attribLastDir} = $dir;
    }
    if ( !exists($fio->{attrib}{$dir}) ) {
        $fio->{attrib}{$dir} = BackupPC::Attrib->new({
				     compress => $fio->{xfer}{compress},
				});
	my $path = $fio->{outDir} . $dir;
        if ( -f $fio->{attrib}{$dir}->fileName($path)
                    && !$fio->{attrib}{$dir}->read($path) ) {
            $fio->log(sprintf("Unable to read attribute file %s",
			    $fio->{attrib}{$dir}->fileName($path)));
        }
    }
    $fio->log("attribSet(dir=$dir, file=$file)") if ( $fio->{logLevel} >= 4 );

    $fio->{attrib}{$dir}->set($file, {
                            type  => $fio->mode2type($f->{mode}),
                            mode  => $f->{mode},
                            uid   => $f->{uid},
                            gid   => $f->{gid},
                            size  => $placeHolder ? -1 : $f->{size},
                            mtime => $f->{mtime},
                       });
    return;
}

sub attribWrite
{
    my($fio, $d) = @_;
    my($poolWrite);

    if ( !defined($d) ) {
        #
        # flush all entries (in reverse order)
        #
        foreach $d ( sort({$b cmp $a} keys(%{$fio->{attrib}})) ) {
            $fio->attribWrite($d);
        }
        return;
    }
    return if ( !defined($fio->{attrib}{$d}) );
    #
    # Set deleted files in the attributes.  Any file in the view
    # that doesn't have attributes is deleted.  All files sent by
    # rsync have attributes temporarily set so we can do deletion
    # detection.  We also prune these temporary attributes.
    #
    if ( $d ne "" ) {
	my $dir;
	my $share;

	$dir = $1 if ( $d =~ m{.+?/(.*)} );
	$fio->viewCacheDir(undef, $dir);
	##print("attribWrite $d,$dir\n");
	##$Data::Dumper::Indent = 1;
	##$fio->log("attribWrite $d,$dir");
	##$fio->log("viewCacheLogKeys = ", keys(%{$fio->{viewCache}}));
	##$fio->log("attribKeys = ", keys(%{$fio->{attrib}}));
	##print "viewCache = ", Dumper($fio->{attrib});
	##print "attrib = ", Dumper($fio->{attrib});
	if ( defined($fio->{viewCache}{$d}) ) {
	    foreach my $f ( keys(%{$fio->{viewCache}{$d}}) ) {
		my $name = $f;
		$name = "$1/$name" if ( $d =~ m{.*?/(.*)} );
		if ( defined(my $a = $fio->{attrib}{$d}->get($f)) ) {
		    #
		    # delete temporary attributes (skipped files)
		    #
		    if ( $a->{size} < 0 ) {
			$fio->{attrib}{$d}->set($f, undef);
			$fio->logFileAction("skip", {
				    %{$fio->{viewCache}{$d}{$f}},
				    name => $name,
				}) if ( $fio->{logLevel} >= 2 );
		    }
		} else {
		    ##print("Delete file $f\n");
		    $fio->logFileAction("delete", {
				%{$fio->{viewCache}{$d}{$f}},
				name => $name,
			    }) if ( $fio->{logLevel} >= 1 );
		    $fio->{attrib}{$d}->set($f, {
				    type  => BPC_FTYPE_DELETED,
				    mode  => 0,
				    uid   => 0,
				    gid   => 0,
				    size  => 0,
				    mtime => 0,
			       });
		}
	    }
	}
    }
    if ( $fio->{attrib}{$d}->fileCount ) {
        my $data = $fio->{attrib}{$d}->writeData;
	my $dirM = $d;

	$dirM = $1 . "/" . $fio->{bpc}->fileNameMangle($2)
			if ( $dirM =~ m{(.*?)/(.*)} );
        my $fileName = $fio->{attrib}{$d}->fileName("$fio->{outDir}$dirM");
	$fio->log("attribWrite(dir=$d) -> $fileName")
				if ( $fio->{logLevel} >= 4 );
        my $poolWrite = BackupPC::PoolWrite->new($fio->{bpc}, $fileName,
                                     length($data), $fio->{xfer}{compress});
        $poolWrite->write(\$data);
        $fio->processClose($poolWrite, $fio->{attrib}{$d}->fileName($d),
                           length($data), 0);
    }
    delete($fio->{attrib}{$d});
}

sub processClose
{
    my($fio, $poolWrite, $fileName, $origSize, $doStats) = @_;
    my($exists, $digest, $outSize, $errs) = $poolWrite->close;

    $fileName =~ s{^/+}{};
    $fio->log(@$errs) if ( defined($errs) && @$errs );
    if ( $doStats ) {
	$fio->{stats}{TotalFileCnt}++;
	$fio->{stats}{TotalFileSize} += $origSize;
    }
    if ( $exists ) {
	if ( $doStats ) {
	    $fio->{stats}{ExistFileCnt}++;
	    $fio->{stats}{ExistFileSize}     += $origSize;
	    $fio->{stats}{ExistFileCompSize} += $outSize;
	}
    } elsif ( $outSize > 0 ) {
        my $fh = $fio->{newFilesFH};
        print($fh "$digest $origSize $fileName\n") if ( defined($fh) );
    }
    return $exists && $origSize > 0;
}

sub statsGet
{
    my($fio) = @_;

    return $fio->{stats};
}

#
# Make a given directory.  Returns non-zero on error.
#
sub mkpath
{
    my($fio, $f) = @_;
    my $name = $1 if ( $f->{name} =~ /(.*)/ );
    my $path;

    if ( $name eq "." ) {
	$path = $fio->{outDirSh};
    } else {
	$path = $fio->{outDirSh} . $fio->{bpc}->fileNameMangle($name);
    }
    $fio->logFileAction("create", $f) if ( $fio->{logLevel} >= 1 );
    $fio->log("mkpath($path, 0777)") if ( $fio->{logLevel} >= 5 );
    $path = $1 if ( $path =~ /(.*)/ );
    File::Path::mkpath($path, 0, 0777) if ( !-d $path );
    return $fio->attribSet($f) if ( -d $path );
    $fio->log("Can't create directory $path");
    return -1;
}

#
# Make a special file.  Returns non-zero on error.
#
sub mkspecial
{
    my($fio, $f) = @_;
    my $name = $1 if ( $f->{name} =~ /(.*)/ );
    my $fNameM = $fio->{bpc}->fileNameMangle($name);
    my $path = $fio->{outDirSh} . $fNameM;
    my $attr = $fio->attribGet($f);
    my $str = "";
    my $type = $fio->mode2type($f->{mode});

    $fio->log("mkspecial($path, $type, $f->{mode})")
		    if ( $fio->{logLevel} >= 5 );
    if ( $type == BPC_FTYPE_CHARDEV || $type == BPC_FTYPE_BLOCKDEV ) {
	my($major, $minor, $fh, $fileData);

	$major = $f->{rdev} >> 8;
	$minor = $f->{rdev} & 0xff;
        $str = "$major,$minor";
    } elsif ( ($f->{mode} & S_IFMT) == S_IFLNK ) {
        $str = $f->{link};
    }
    #
    # Now see if the file is different, or this is a full, in which
    # case we create the new file.
    #
    my($fh, $fileData);
    if ( $fio->{full}
            || !defined($attr)
            || $attr->{type}  != $fio->mode2type($f->{mode})
            || $attr->{mtime} != $f->{mtime}
            || $attr->{size}  != $f->{size}
            || $attr->{gid}   != $f->{gid}
            || $attr->{mode}  != $f->{mode}
            || !defined($fh = BackupPC::FileZIO->open($attr->{fullPath}, 0,
                                                      $attr->{compress}))
            || $fh->read(\$fileData, length($str) + 1) != length($str)
            || $fileData ne $str ) {
        $fh->close if ( defined($fh) );
        $fh = BackupPC::PoolWrite->new($fio->{bpc}, $path,
                                     length($str), $fio->{xfer}{compress});
	$fh->write(\$str);
	my $exist = $fio->processClose($fh, "$fio->{shareM}/$fNameM",
				       length($str), 1);
	$fio->logFileAction($exist ? "pool" : "create", $f)
			    if ( $fio->{logLevel} >= 1 );
	return $fio->attribSet($f);
    } else {
	$fio->logFileAction("skip", $f) if ( $fio->{logLevel} >= 2 );
    }
    $fh->close if ( defined($fh) );
}

sub unlink
{
    my($fio, $path) = @_;
    
    $fio->log("Unexpected call BackupPC::Xfer::RsyncFileIO->unlink($path)"); 
}

#
# Appends to list of log messages
#
sub log
{
    my($fio, @msg) = @_;

    $fio->{log} ||= [];
    push(@{$fio->{log}}, @msg);
}

#
# Generate a log file message for a completed file
#
sub logFileAction
{
    my($fio, $action, $f) = @_;
    my $owner = "$f->{uid}/$f->{gid}";
    my $type  = (("", "p", "c", "", "d", "", "b", "", "", "", "l", "", "s"))
		    [($f->{mode} & S_IFMT) >> 12];

    $fio->log(sprintf("  %-6s %1s%4o %9s %11.0f %s",
				$action,
				$type,
				$f->{mode} & 07777,
				$owner,
				$f->{size},
				$f->{name}));
}

#
# Returns a list of log messages
#
sub logMsg
{
    my($fio) = @_;
    my $log = $fio->{log} || [];

    delete($fio->{log});
    return @$log;
}

#
# Start receive of file deltas for a particular file.
#
sub fileDeltaRxStart
{
    my($fio, $f, $cnt, $size, $remainder) = @_;

    $fio->{rxFile}      = $f;           # remote file attributes
    $fio->{rxLocalAttr} = $fio->attribGet($f); # local file attributes
    $fio->{rxBlkCnt}    = $cnt;         # how many blocks we will receive
    $fio->{rxBlkSize}   = $size;        # block size
    $fio->{rxRemainder} = $remainder;   # size of the last block
    $fio->{rxMatchBlk}  = 0;            # current start of match
    $fio->{rxMatchNext} = 0;            # current next block of match
    my $rxSize = ($cnt - 1) * $size + $remainder;
    if ( $fio->{rxFile}{size} != $rxSize ) {
        $fio->{rxMatchBlk} = undef;     # size different, so no file match
        $fio->log("$fio->{rxFile}{name}: size doesn't match"
                  . " ($fio->{rxFile}{size} vs $rxSize)")
                        if ( $fio->{logLevel} >= 5 );
    }
    delete($fio->{rxInFd});
    delete($fio->{rxOutFd});
    delete($fio->{rxDigest});
    delete($fio->{rxInData});
}

#
# Process the next file delta for the current file.  Returns 0 if ok,
# -1 if not.  Must be called with either a block number, $blk, or new data,
# $newData, (not both) defined.
#
sub fileDeltaRxNext
{
    my($fio, $blk, $newData) = @_;

    if ( defined($blk) ) {
        if ( defined($fio->{rxMatchBlk}) && $fio->{rxMatchNext} == $blk ) {
            #
            # got the next block in order; just keep track.
            #
            $fio->{rxMatchNext}++;
            return;
        }
    }
    my $newDataLen = length($newData);
    $fio->log("$fio->{rxFile}{name}: blk=$blk, newData=$newDataLen, rxMatchBlk=$fio->{rxMatchBlk}, rxMatchNext=$fio->{rxMatchNext}")
		    if ( $fio->{logLevel} >= 8 );
    if ( !defined($fio->{rxOutFd}) ) {
	#
	# maybe the file has no changes
	#
	if ( $fio->{rxMatchNext} == $fio->{rxBlkCnt}
		&& !defined($blk) && !defined($newData) ) {
	    #$fio->log("$fio->{rxFile}{name}: file is unchanged");
	    #		    if ( $fio->{logLevel} >= 8 );
	    return;
	}

        #
        # need to open an output file where we will build the
        # new version.
        #
        $fio->{rxFile}{name} =~ /(.*)/;
	my $rxOutFileRel = "$fio->{shareM}/" . $fio->{bpc}->fileNameMangle($1);
        my $rxOutFile    = $fio->{outDir} . $rxOutFileRel;
        $fio->{rxOutFd}  = BackupPC::PoolWrite->new($fio->{bpc},
					   $rxOutFile, $fio->{rxFile}{size},
                                           $fio->{xfer}{compress});
        $fio->log("$fio->{rxFile}{name}: opening output file $rxOutFile")
                        if ( $fio->{logLevel} >= 10 );
        $fio->{rxOutFile} = $rxOutFile;
        $fio->{rxOutFileRel} = $rxOutFileRel;
        $fio->{rxDigest} = File::RsyncP::Digest->new;
        $fio->{rxDigest}->add(pack("V", $fio->{checksumSeed}));
    }
    if ( defined($fio->{rxMatchBlk})
                && $fio->{rxMatchBlk} != $fio->{rxMatchNext} ) {
        #
        # Need to copy the sequence of blocks that matched.  If the file
        # is compressed we need to make a copy of the uncompressed file,
        # since the compressed file is not seekable.  Future optimizations
        # would be to keep the uncompressed file in memory (eg, up to say
        # 10MB), only create an uncompressed copy if the matching
        # blocks were not monotonic, and to only do this if there are
        # matching blocks (eg, maybe the entire file is new).
        #
        my $attr = $fio->{rxLocalAttr};
	my $fh;
        if ( !defined($fio->{rxInFd}) && !defined($fio->{rxInData}) ) {
            if ( $attr->{compress} ) {
                if ( !defined($fh = BackupPC::FileZIO->open(
                                                   $attr->{fullPath},
                                                   0,
                                                   $attr->{compress})) ) {
                    $fio->log("Can't open $attr->{fullPath}");
                    return -1;
                }
                if ( $attr->{size} < 10 * 1024 * 1024 ) {
                    #
                    # Cache the entire old file if it is less than 10MB
                    #
                    my $data;
                    $fio->{rxInData} = "";
                    while ( $fh->read(\$data, 10 * 1024 * 1024) > 0 ) {
                        $fio->{rxInData} .= $data;
                    }
                } else {
                    #
                    # Create and write a temporary output file
                    #
                    unlink("$fio->{outDirSh}RStmp")
                                    if  ( -f "$fio->{outDirSh}RStmp" );
                    if ( open(F, ">+$fio->{outDirSh}RStmp") ) {
                        my $data;
                        while ( $fh->read(\$data, 1024 * 1024) > 0 ) {
                            if ( syswrite(F, $data) != length($data) ) {
                                $fio->log(sprintf("Can't write len=%d to %s",
				      length($data) , "$fio->{outDirSh}RStmp"));
                                $fh->close;
                                return -1;
                            }
                        }
                        $fio->{rxInFd} = *F;
                        $fio->{rxInName} = "$fio->{outDirSh}RStmp";
                        seek($fio->{rxInFd}, 0, 0);
                    } else {
                        $fio->log("Unable to open $fio->{outDirSh}RStmp");
                        $fh->close;
                        return -1;
                    }
                }
                $fh->close;
            } else {
                if ( open(F, $attr->{fullPath}) ) {
                    $fio->{rxInFd} = *F;
                    $fio->{rxInName} = $attr->{fullPath};
                } else {
                    $fio->log("Unable to open $attr->{fullPath}");
                    return -1;
                }
            }
        }
	my $lastBlk = $fio->{rxMatchNext} - 1;
        $fio->log("$fio->{rxFile}{name}: writing blocks $fio->{rxMatchBlk}.."
                  . "$lastBlk")
                        if ( $fio->{logLevel} >= 10 );
        my $seekPosn = $fio->{rxMatchBlk} * $fio->{rxBlkSize};
        if ( defined($fio->{rxInFd}) && !seek($fio->{rxInFd}, $seekPosn, 0) ) {
            $fio->log("Unable to seek $attr->{fullPath} to $seekPosn");
            return -1;
        }
        my $cnt = $fio->{rxMatchNext} - $fio->{rxMatchBlk};
        my($thisCnt, $len, $data);
        for ( my $i = 0 ; $i < $cnt ; $i += $thisCnt ) {
            $thisCnt = $cnt - $i;
            $thisCnt = 512 if ( $thisCnt > 512 );
            if ( $fio->{rxMatchBlk} + $i + $thisCnt == $fio->{rxBlkCnt} ) {
                $len = ($thisCnt - 1) * $fio->{rxBlkSize} + $fio->{rxRemainder};
            } else {
                $len = $thisCnt * $fio->{rxBlkSize};
            }
            if ( defined($fio->{rxInData}) ) {
                $data = substr($fio->{rxInData}, $seekPosn, $len);
            } else {
                if ( sysread($fio->{rxInFd}, $data, $len) != $len ) {
                    $fio->log("Unable to read $len bytes from"
                              . " $fio->{rxInName} "
                              . "($i,$thisCnt,$fio->{rxBlkCnt})");
                    return -1;
                }
            }
            $fio->{rxOutFd}->write(\$data);
            $fio->{rxDigest}->add($data);
        }
        $fio->{rxMatchBlk} = undef;
    }
    if ( defined($blk) ) {
        #
        # Remember the new block number
        #
        $fio->{rxMatchBlk}  = $blk;
        $fio->{rxMatchNext} = $blk + 1;
    }
    if ( defined($newData) ) {
        #
        # Write the new chunk
        #
        my $len = length($newData);
        $fio->log("$fio->{rxFile}{name}: writing $len bytes new data")
                        if ( $fio->{logLevel} >= 10 );
        $fio->{rxOutFd}->write(\$newData);
        $fio->{rxDigest}->add($newData);
    }
}

#
# Finish up the current receive file.  Returns undef if ok, -1 if not.
# Returns 1 if the md4 digest doesn't match.
#
sub fileDeltaRxDone
{
    my($fio, $md4) = @_;
    my $name = $1 if ( $fio->{rxFile}{name} =~ /(.*)/ );

    if ( !defined($fio->{rxDigest}) ) {
        #
        # File was exact match, but we still need to verify the
        # MD4 checksum.  Therefore open and read the file.
        #
        $fio->{rxDigest} = File::RsyncP::Digest->new;
        $fio->{rxDigest}->add(pack("V", $fio->{checksumSeed}));
        my $attr = $fio->{rxLocalAttr};
        if ( defined($attr) && defined(my $fh = BackupPC::FileZIO->open(
						       $attr->{fullPath},
						       0,
						       $attr->{compress})) ) {
            my $data;
	    while ( $fh->read(\$data, 4 * 65536) > 0 ) {
		$fio->{rxDigest}->add($data);
	    }
            $fh->close;
        } else {
	    # error
	}
        $fio->log("$name got exact match")
                        if ( $fio->{logLevel} >= 5 );
    }
    close($fio->{rxInFd})  if ( defined($fio->{rxInFd}) );
    unlink("$fio->{outDirSh}RStmp") if  ( -f "$fio->{outDirSh}RStmp" );
    my $newDigest = $fio->{rxDigest}->rsyncDigest;
    if ( $fio->{logLevel} >= 3 ) {
        my $md4Str = unpack("H*", $md4);
        my $newStr = unpack("H*", $newDigest);
        $fio->log("$name got digests $md4Str vs $newStr")
    }
    if ( $md4 ne $newDigest ) {
        $fio->log("$name md4 doesn't match")
                    if ( $fio->{logLevel} >= 1 );
        if ( defined($fio->{rxOutFd}) ) {
            $fio->{rxOutFd}->close;
            unlink($fio->{rxOutFile});
        }
        return 1;
    }
    #
    # One special case is an empty file: if the file size is
    # zero we need to open the output file to create it.
    #
    if ( $fio->{rxFile}{size} == 0 ) {
	my $rxOutFileRel = "$fio->{shareM}/"
			 . $fio->{bpc}->fileNameMangle($name);
        my $rxOutFile    = $fio->{outDir} . $rxOutFileRel;
        $fio->{rxOutFd}  = BackupPC::PoolWrite->new($fio->{bpc},
					   $rxOutFile, $fio->{rxFile}{size},
                                           $fio->{xfer}{compress});
    }
    if ( !defined($fio->{rxOutFd}) ) {
        #
        # No output file, meaning original was an exact match.
        #
        $fio->log("$name: nothing to do")
                        if ( $fio->{logLevel} >= 5 );
        my $attr = $fio->{rxLocalAttr};
        my $f = $fio->{rxFile};
	$fio->logFileAction("same", $f) if ( $fio->{logLevel} >= 1 );
        if ( $fio->{full}
                || $attr->{type}  != $f->{type}
                || $attr->{mtime} != $f->{mtime}
                || $attr->{size}  != $f->{size}
                || $attr->{gid}   != $f->{gid}
                || $attr->{mode}  != $f->{mode} ) {
            #
            # In the full case, or if the attributes are different,
            # we need to make a link from the previous file and
            # set the attributes.
            #
            my $rxOutFile = $fio->{outDirSh}
                            . $fio->{bpc}->fileNameMangle($name);
            if ( !link($attr->{fullPath}, $rxOutFile) ) {
                $fio->log("Unable to link $attr->{fullPath} to $rxOutFile");
                return -1;
            }
	    #
	    # Cumulate the stats
	    #
	    $fio->{stats}{TotalFileCnt}++;
	    $fio->{stats}{TotalFileSize} += $fio->{rxFile}{size};
	    $fio->{stats}{ExistFileCnt}++;
	    $fio->{stats}{ExistFileSize} += $fio->{rxFile}{size};
	    $fio->{stats}{ExistFileCompSize} += -s $rxOutFile;
            return;
        }
    }
    if ( defined($fio->{rxOutFd}) ) {
	my $exist = $fio->processClose($fio->{rxOutFd},
				       $fio->{rxOutFileRel},
				       $fio->{rxFile}{size}, 1);
	$fio->logFileAction($exist ? "pool" : "create", $fio->{rxFile})
			    if ( $fio->{logLevel} >= 1 );
    }
    delete($fio->{rxDigest});
    delete($fio->{rxInData});
    return;
}

sub fileListEltSend
{
    my($fio, $name, $fList, $outputFunc) = @_;
    my @s = stat($name);

    (my $n = $name) =~ s/^\Q$fio->{localDir}/$fio->{remoteDir}/;
    $fList->encode({
            fname => $n,
            dev   => $s[0],
            inode => $s[1],
            mode  => $s[2],
            uid   => $s[4],
            gid   => $s[5],
            rdev  => $s[6],
            mtime => $s[9],
        });
    &$outputFunc($fList->encodeData);
}

sub fileListSend
{
    my($fio, $flist, $outputFunc) = @_;

    $fio->log("fileListSend not implemented!!");
    $fio->{view}->find($fio->{lastBkupNum}, $fio->{xfer}{shareName},
                       $fio->{restoreFiles}, 1, \&fileListEltSend,
                       $flist, $outputFunc);
}

sub finish
{
    my($fio, $isChild) = @_;

    #
    # Flush the attributes if this is the child
    #
    $fio->attribWrite(undef)
}


sub is_tainted
{
    return ! eval {
        join('',@_), kill 0;
        1;
    };
}

1;