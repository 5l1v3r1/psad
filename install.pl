#!/usr/bin/perl -w
#
#########################################################################
#
# File: install.pl
#
# Purpose:  install.pl is the installation script for psad.  It is safe
#           to execute install.pl even if psad has already been installed
#           on a system since install.pl will preserve the existing
#           config section within the new script.
#
# Credits:  (see the CREDITS file)
#
# Version: 1.0
#
# Copyright (C) 1999-2002 Michael B. Rash (mbr@cipherdyne.com)
#
# License (GNU Public License):
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program; if not, write to the Free Software
#    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307
#    USA
#
# TODO:
#   - make install.pl preserve psad_signatures and psad_auto_ips
#     with "diff" and "patch" from the old to the new.
#
#########################################################################
#
# $Id$
#

use File::Path;
use File::Copy;
use Text::Wrap;
use Sys::Hostname;
use IO::Socket;
use Getopt::Long;
use strict;

### Note that Psad.pm is not included within the above list (installation
### over existing psad should not make use of an old Psad.pm).

### These three variables should not really be changed unless
### you're really sure.
my $PSAD_DIR     = '/var/log/psad';
my $PSAD_CONFDIR = '/etc/psad';
my $VARLIBDIR    = '/var/lib/psad';
my $RUNDIR       = '/var/run/psad';
my $LIBDIR       = '/usr/lib/psad';

#============== config ===============
my $INSTALL_LOG  = "${PSAD_DIR}/install.log";
my $PSAD_FIFO    = "${VARLIBDIR}/psadfifo";
my $INIT_DIR     = '/etc/rc.d/init.d';
my $USRSBIN_DIR  = '/usr/sbin';  ### consistent with FHS (Filesystem
                                 ### Hierarchy Standard)
my $CONF_ARCHIVE = "${PSAD_CONFDIR}/archive";
my @LOGR_FILES   = (*STDOUT, $INSTALL_LOG);
my $RUNLEVEL;    ### This should only be set if install.pl
                 ### cannot determine the correct runlevel
my $WHOIS_PSAD   = '/usr/bin/whois.psad';

### system binaries ###
my $chkconfigCmd = '/sbin/chkconfig';
my $gzipCmd      = '/usr/bin/gzip';
my $psCmd        = '/bin/ps';
my $netstatCmd   = '/bin/netstat';
my $ifconfigCmd  = '/sbin/ifconfig';
my $mknodCmd     = '/bin/mknod';
my $makeCmd      = '/usr/bin/make';
my $killallCmd   = '/usr/bin/killall';
my $perlCmd      = '/usr/bin/perl';
my $ipchainsCmd  = '/sbin/ipchains';
my $iptablesCmd  = '/sbin/iptables';
my $psadCmd      = "${USRSBIN_DIR}/psad";
#============ end config ============

### get the hostname of the system
my $HOSTNAME = hostname;

if (-e $INSTALL_LOG) {
    open INSTALL, "> $INSTALL_LOG" or
        die " ** Could not open $INSTALL_LOG: $!";
    close INSTALL;
}

### scope these vars
my $PERL_INSTALL_DIR;  ### This is used to find pre-0.9.2 installations of psad

### set the install directory for the Psad.pm module
my $found = 0;
for my $dir (@INC) {
    if ($dir =~ /site_perl\/\d\S+/) {
        $PERL_INSTALL_DIR = $dir;
        $found = 1;
        last;
    }
}
unless ($found) {
    $PERL_INSTALL_DIR = $INC[0];
}

### set the default execution flags
my $SUB_TAB = '    ';
my $nopreserve   = 0;
my $uninstall    = 0;
my $verbose      = 0;
my $help         = 0;

&usage(1) unless (GetOptions(
    'no-preserve' => \$nopreserve,    # don't preserve existing configs
    'uninstall'   => \$uninstall,
    'verbose'     => \$verbose,
    'help'        => \$help           # display help
));
&usage(0) if ($help);

my %Cmds = (
    'ps'       => $psCmd,
    'mknod'    => $mknodCmd,
    'netstat'  => $netstatCmd,
    'ifconfig' => $ifconfigCmd,
    'make'     => $makeCmd,
    'killall'  => $killallCmd,
    'perl'     => $perlCmd,
    'ipchains' => $ipchainsCmd,
    'iptables' => $iptablesCmd,
);

my $distro = &get_distro();

### add chkconfig only if we are runing on a redhat distro
if ($distro =~ /red.*hat/i) {
    $Cmds{'chkconfig'} = $chkconfigCmd;
}

### need to make sure this exists before attempting to
### write anything to the install log.
unless (-d $PSAD_DIR) {
    mkdir $PSAD_DIR, 0500;
}

&check_commands();
$Cmds{'psad'} = $psadCmd;

### check to make sure we are running as root
$< == 0 && $> == 0 or die "You need to be root (or equivalent UID 0" .
    " account) to install/uninstall psad!\n";

### check for a pre-0.9.2 installation of psad.
&check_old_psad_installation();

if ($uninstall) {
    &uninstall();
} else {
    &install();
}
exit 0;
#================= end main =================

sub install() {
    ### make sure install.pl is being called from the source directory
    unless (-e 'psad' && -e 'Psad.pm/Psad.pm') {
        die " ** install.pl can only be executed from the directory" .
            " that contains the psad sources!  Exiting.\n\n";
    }
    &logr("\n .. " . localtime() . " Installing psad on hostname: $HOSTNAME\n");
    unless (-d $RUNDIR) {
        &logr(" .. Creating $RUNDIR\n");
        mkdir $RUNDIR, 0500;
    }
    unless (-d $VARLIBDIR) {
        &logr(" .. Creating $VARLIBDIR\n");
        mkdir $VARLIBDIR, 0500;
    }
    unless (-d $LIBDIR) {
        &logr(" .. Creating $LIBDIR\n");
        mkdir $LIBDIR, 0500;
    }
    unless (-d $PSAD_CONFDIR) {
        &logr(" .. Creating $PSAD_CONFDIR\n");
        mkdir $PSAD_CONFDIR, 0500;
    }
    unless (-d $CONF_ARCHIVE) {
        &logr(" .. Creating $CONF_ARCHIVE\n");
        mkdir $CONF_ARCHIVE, 0500;
    }
    unless (-e $PSAD_FIFO) {
        &logr(" .. Creating named pipe $PSAD_FIFO\n");
        unless (((system "$Cmds{'mknod'} -m 600 $PSAD_FIFO p")>>8) == 0) {
            &logr(" ** Could not create the named pipe \"$PSAD_FIFO\"!" .
                " ** Psad requires this file to exist!  Aborting install.\n");
            die;
        }
        unless (-p $PSAD_FIFO) {
            &logr(" ** Could not create the named pipe \"$PSAD_FIFO\"!" .
                " ** Psad requires this file to exist!  Aborting " .
                "install.\n");
            die;
        }
    }

    my $restarted_syslog = 0;
    if (-e '/etc/syslog.conf') {
        &append_fifo_syslog();
        if (((system "$Cmds{'killall'} -HUP syslogd 2> /dev/null")>>8) == 0) {
            &logr(" .. Restarted syslog.\n");
            $restarted_syslog = 1;
        }
    }
    if (-e '/etc/syslog-ng/syslog-ng.conf') {
        &append_fifo_syslog_ng();
        if (((system "$Cmds{'killall'} -HUP syslog-ng 2> /dev/null")>>8) == 0) {
            &logr(" .. Restarted syslog-ng.\n");
            $restarted_syslog = 1;
        }
    }
#    &append_metalog();   ### metalog support some day

    ### restart any running syslog daemon (killall should really work here)
#    &hup_syslog();

    unless ($restarted_syslog) {
        &logr(" ** Could not restart any syslog daemons.\n");
    }
    unless (-d $PSAD_DIR) {
        &logr(" .. Creating $PSAD_DIR\n");
        mkdir $PSAD_DIR, 0500;
    }
    unless (-e "${PSAD_DIR}/fwdata") {
        &logr(" .. Creating ${PSAD_DIR}/fwdata file\n");
        open F, "> ${PSAD_DIR}/fwdata";
        close F;
        chmod 0600, "${PSAD_DIR}/fwdata";
        &perms_ownership("${PSAD_DIR}/fwdata", 0600);
    }

    unless (-d $USRSBIN_DIR) {
        &logr(" .. Creating $USRSBIN_DIR\n");
        mkdir $USRSBIN_DIR,0755;
    }
    if (-d 'whois-4.6.2') {
        &logr(" .. Compiling Marco d'Itri's whois client\n");
        system "$Cmds{'make'} -C whois-4.6.2";
        if (-e 'whois-4.6.2/whois') {
            &logr(" .. Copying whois binary to $WHOIS_PSAD\n");
            copy "whois-4.6.2/whois", $WHOIS_PSAD;
        } else {
            die " ** Could not compile whois-4.6.2";
        }
    }
    &perms_ownership($WHOIS_PSAD, 0755);

    ### installing Psad.pm
    &logr(" .. Installing the Psad.pm perl module\n");

    chdir 'Psad.pm';
    unless (-e 'Makefile.PL' && -e 'Psad.pm') {
        die " ** Your source distribution appears to be incomplete!  " .
            "Psad.pm is missing.\n    Download the latest sources from " .
            "http://www.cipherdyne.com\n";
    }
    system "$Cmds{'perl'} Makefile.PL PREFIX=$LIBDIR LIB=$LIBDIR";
    system  $Cmds{'make'};
    system "$Cmds{'make'} test";
    system "$Cmds{'make'} install";
    chdir '..';

    print "\n\n";

    ### installing Unix::Syslog
    &logr(" .. Installing the Unix::Syslog perl module\n");

    chdir 'Unix-Syslog-0.100' or die " ** Could not chdir to ",
        "Unix-Syslog-0.100: $!";
    unless (-e 'Makefile.PL' && -e 'Syslog.pm') {
        die " ** Your source directory appears to be incomplete!  Syslog.pm " .
            "is missing.\n    Download the latest sources from " .
            "http://www.cipherdyne.com\n";
    }
#    system "$Cmds{'perl'} Makefile.PL PREFIX=$LIBDIR INST_ARCHLIB=$LIBDIR LIB=$LIBDIR";
#    system "$Cmds{'perl'} Makefile.PL PREFIX=$LIBDIR LIB=$LIBDIR";
    system "$Cmds{'perl'} Makefile.PL";
    system "$Cmds{'make'}";
#    system "$Cmds{'make'} test";
    system "$Cmds{'make'} install";
    chdir '..';

    print "\n\n";

    &logr(" .. Setting hostname to \"$HOSTNAME\" in psad.h\n");
    if (-e 'psad.h') {
        open P, "< psad.h";
        my @lines = <P>;
        close P;
        ### replace the "#define HOSTNAME HOSTNAME" line with $HOSTNAME
        open PH, "> psad.h";
        for my $line (@lines) {
            chomp $line;
            if ($line =~ /^#define\s+HOSTNAME\s+\"HOSTNAME\"/) {
                print PH "#define HOSTNAME \"$HOSTNAME\"\n";
            } else {
                print PH $line . "\n";
            }
        }
        close PH;
    } else {
        die " ** Your source directory appears to be incomplete!  psad.h " .
            "is missing.\n    Download the latest sources from " .
            "http://www.cipherdyne.com\n";
    }

    &logr(" .. Compiling kmsgsd, psadwatchd, and diskmond:\n");

    ### remove any previously compiled kmsgsd
    unlink 'kmsgsd' if -e 'kmsgsd';

    ### remove any previously compiled psadwatchd
    unlink 'psadwatchd' if -e 'psadwatchd';

    ### remove any previously compiled diskmond
    unlink 'diskmond' if -e 'diskmond';

    ### compile the C psad daemons
    system $Cmds{'make'};
    if (! -e 'kmsgsd' && -e 'kmsgsd.pl') {
        &logr(" ** Could not compile kmsgsd.c.  Installing perl kmsgsd.\n");
        unless (((system "$Cmds{'perl'} -c kmsgsd.pl")>>8) == 0) {
            die " ** kmsgsd.pl does not compile with \"perl -c\".  " .
                "Download the latest sources " .
                "from:\n\nhttp://www.cipherdyne.com\n";
        }
        copy 'kmsgsd.pl', 'kmsgsd';
    }
    if (! -e 'psadwatchd' && -e 'psadwatchd.pl') {
        &logr(" ** Could not compile psadwatchd.c.  " .
            "Installing perl psadwatchd.\n");
        unless (((system "$Cmds{'perl'} -c psadwatchd.pl")>>8) == 0) {
            die " ** psadwatchd.pl does not compile with \"perl -c\".  " .
                "Download the latest sources " .
                "from:\n\nhttp://www.cipherdyne.com\n";
        }
        copy 'psadwatchd.pl', 'psadwatchd';
    }

    if (! -e 'diskmond' && -e 'diskmond.pl') {
        &logr(" ** Could not compile diskmond.c.  Installing " .
            "perl diskmond.\n");
        unless (((system "$Cmds{'perl'} -c diskmond.pl")>>8) == 0) {
            die " ** diskmond.pl does not compile with \"perl -c\".  " .
                "Download the latest sources " .
                "from:\n\nhttp://www.cipherdyne.com\n";
        }
        copy 'diskmond.pl', 'diskmond';
    }

    print "\n\n";
    ### make sure the psad (perl) daemon compiles.  The other three
    ### daemons have all been re-written in C.
    &logr(" .. Verifying compilation of psad (perl) daemons:\n");
    unless (((system "$Cmds{'perl'} -c psad")>>8) == 0) {
        die " ** psad does not compile with \"perl -c\".  Download the" .
            " latest sources from:\n\nhttp://www.cipherdyne.com\n";
    }
    print "\n";
    print "\n";

    ### put the psad daemons in place
    &logr(" .. Copying psad -> ${USRSBIN_DIR}/psad\n");
    unlink "${USRSBIN_DIR}/psad" if -e "${USRSBIN_DIR}/psad";
    copy 'psad', "${USRSBIN_DIR}/psad";
    &perms_ownership("${USRSBIN_DIR}/psad", 0500);

    &logr(" .. Copying psadwatchd -> ${USRSBIN_DIR}/psadwatchd\n");
    unlink "${USRSBIN_DIR}/psadwatchd" if -e "${USRSBIN_DIR}/psadwatchd";
    copy 'psadwatchd', "${USRSBIN_DIR}/psadwatchd";
    &perms_ownership("${USRSBIN_DIR}/psadwatchd", 0500);

    &logr(" .. Copying kmsgsd -> ${USRSBIN_DIR}/kmsgsd\n");
    unlink "${USRSBIN_DIR}/kmsgsd" if -e "${USRSBIN_DIR}/kmsgsd";
    copy 'kmsgsd', "${USRSBIN_DIR}/kmsgsd";
    &perms_ownership("${USRSBIN_DIR}/kmsgsd", 0500);

    &logr(" .. Copying diskmond -> ${USRSBIN_DIR}/diskmond\n");
    unlink "${USRSBIN_DIR}/diskmond" if -e "${USRSBIN_DIR}/diskmond";
    copy 'diskmond', "${USRSBIN_DIR}/diskmond";
    &perms_ownership("${USRSBIN_DIR}/diskmond", 0500);

    unless (-d $PSAD_CONFDIR) {
        &logr(" .. Creating $PSAD_CONFDIR\n");
        mkdir $PSAD_CONFDIR,0500;
    }
    unless (-d $CONF_ARCHIVE) {
        &logr(" .. Creating $CONF_ARCHIVE\n");
        mkdir $CONF_ARCHIVE, 0500;
    }
    if (-e "${PSAD_CONFDIR}/psad_signatures") {
        &archive("${PSAD_CONFDIR}/psad_signatures") unless $nopreserve;
        &logr(" .. Copying psad_signatures -> " .
            "${PSAD_CONFDIR}/psad_signatures\n");
        copy 'psad_signatures', "${PSAD_CONFDIR}/psad_signatures";
        &perms_ownership("${PSAD_CONFDIR}/psad_signatures", 0600);
    } else {
        &logr(" .. Copying psad_signatures -> " .
            "${PSAD_CONFDIR}/psad_signatures\n");
        copy 'psad_signatures', "${PSAD_CONFDIR}/psad_signatures";
        &perms_ownership("${PSAD_CONFDIR}/psad_signatures", 0600);
    }
    if (-e "${PSAD_CONFDIR}/psad_auto_ips") {
        &archive("${PSAD_CONFDIR}/psad_auto_ips") unless $nopreserve;
        &logr(" .. Copying psad_auto_ips -> " .
            "${PSAD_CONFDIR}/psad_auto_ips\n");
        copy 'psad_auto_ips', "${PSAD_CONFDIR}/psad_auto_ips";
        &perms_ownership("${PSAD_CONFDIR}/psad_auto_ips", 0600);
    } else {
        &logr(" .. Copying psad_auto_ips -> " .
            "${PSAD_CONFDIR}/psad_auto_ips\n");
        copy 'psad_auto_ips', "${PSAD_CONFDIR}/psad_auto_ips";
        &perms_ownership("${PSAD_CONFDIR}/psad_auto_ips", 0600);
    }
    if (-e "${PSAD_CONFDIR}/psad.conf") {
        &archive("${PSAD_CONFDIR}/psad.conf") unless $nopreserve;
        &logr(" .. Copying psad.conf -> ${PSAD_CONFDIR}/psad.conf\n");
        copy 'psad.conf', "${PSAD_CONFDIR}/psad.conf";
        &perms_ownership("${PSAD_CONFDIR}/psad.conf", 0600);
    } else {
        &logr(" .. Copying psad.conf -> ${PSAD_CONFDIR}/psad.conf\n");
        copy 'psad.conf', "${PSAD_CONFDIR}/psad.conf";
        &perms_ownership("${PSAD_CONFDIR}/psad.conf", 0600);
    }

    if ($Cmds{'iptables'} && -x $Cmds{'iptables'}) {
        &logr(" .. Found iptables.  Testing syslog configuration.\n");
        ### make sure we actually see packets being logged by
        ### the firewall.
        &test_syslog_config();
    }

    my $email_str = &query_email();
    if ($email_str) {
        &put_email("${PSAD_CONFDIR}/psad.conf", $email_str);
    }
    ### Give the admin the opportunity to add to the strings that are normally
    ### checked in iptables messages.  This is useful since the admin may have
    ### configured the firewall to use a logging prefix of "Audit" or something
    ### else other than the normal "DROP", "DENY", or "REJECT" strings.
    my $custom_fw_search_str = &get_fw_search_string();
    if ($custom_fw_search_str) {
        &logr(" .. Setting \$FW_MSG_SEARCH1 to \"$custom_fw_search_str\" " .
            "in ${PSAD_CONFDIR}/psad.conf\n");
        &put_custom_fw_search_str("${PSAD_CONFDIR}/psad.conf",
            $custom_fw_search_str);
    }
    ### make sure the PSAD_DIR and PSAD_FIFO variables are correctly defined
    ### in the config file.
    &put_string("${PSAD_CONFDIR}/psad.conf", 'PSAD_DIR', $PSAD_DIR);
    &put_string("${PSAD_CONFDIR}/psad.conf", 'PSAD_FIFO', $PSAD_FIFO);

    &install_manpage('psad.8');
    &install_manpage('psadwatchd.8');
    &install_manpage('kmsgsd.8');
    &install_manpage('diskmond.8');

    if ($distro =~ /redhat/i) {
        if (-d $INIT_DIR) {
            &logr(" .. Copying psad-init -> ${INIT_DIR}/psad\n");
            copy 'psad-init', "${INIT_DIR}/psad";
            &perms_ownership("${INIT_DIR}/psad", 0744);
            &enable_psad_at_boot($distro);
        } else {
            &logr(" **  The init script directory, \"${INIT_DIR}\" " .
                "does not exist!.\n");
            &logr("Edit the \$INIT_DIR variable in the config section to " .
                "point to where the init scripts are.\n");
        }
    } else {  ### psad is being installed on a non-redhat distribution
        if (-d $INIT_DIR) {
            &logr(" .. Copying psad-init.generic -> ${INIT_DIR}/psad\n");
            copy 'psad-init.generic', "${INIT_DIR}/psad";
            &perms_ownership("${INIT_DIR}/psad", 0744);
            &enable_psad_at_boot($distro);
        } else {
            &logr(" **  The init script directory, \"${INIT_DIR}\" does " .
                "not exist!.  Edit the \$INIT_DIR variable in the config " .
                "section.\n");
        }
    }
    my $running;
    my $pid;
    if (-e "${RUNDIR}/psad.pid") {
        open PID, "< ${RUNDIR}/psad.pid";
        $pid = <PID>;
        close PID;
        chomp $pid;
        $running = kill 0, $pid;
    } else {
        $running = 0;
    }
    if ($running) {
        &logr(" .. An older version of psad is already running.  To ".
            "start the new version, run \"${USRSBIN_DIR}/psad --Restart\"\n");
    } else {
        &logr(" .. To execute psad, run \"${INIT_DIR}/psad start\"\n");
    }
    &logr("\n .. Psad has been installed!\n");
    return;
}

sub uninstall() {
    &logr("\n .. Uninstalling psad from $HOSTNAME: " . localtime() . "\n");

    my $ans = '';
    while ($ans ne 'y' && $ans ne 'n') {
        print wrap('', $SUB_TAB, ' .. This will completely remove psad ' .
            'from your system.  Are you sure (y/n)? ');
        $ans = <STDIN>;
        chomp $ans;
    }
    if ($ans eq 'n') {
        &logr(" ** User aborted uninstall by answering \"n\" to the remove " .
            "question!  Exiting.\n");
        exit 0;
    }
    ### after this point, psad will really be uninstalled so stop writing stuff
    ### to the install.log file.  Just print everything to STDOUT
    if (-e "${RUNDIR}/psad.pid") {
        if (open PID, "${RUNDIR}/psad.pid") {
            my $pid = <PID>;
            close PID;
            chomp $pid;
            if (kill 0, $pid) {
                print " .. Stopping psad daemons!\n";
                if (-e "${INIT_DIR}/psad") {  ### prefer this for old versions
                    system "${INIT_DIR}/psad stop";
                } else {
                    system "${USRSBIN_DIR}/psad --Kill";
                }
            }
        }
    }
    if (-e "${USRSBIN_DIR}/psad") {
        print wrap('', $SUB_TAB, " .. Removing psad daemons: ${USRSBIN_DIR}/" .
            "(psad, psadwatchd, kmsgsd, diskmond)\n");
        unlink "${USRSBIN_DIR}/psad"       or
            warn " **  Could not remove ${USRSBIN_DIR}/psad!!!\n";
        unlink "${USRSBIN_DIR}/psadwatchd" or
            warn " **  Could not remove ${USRSBIN_DIR}/psadwatchd!!!\n";
        unlink "${USRSBIN_DIR}/kmsgsd"     or
            warn " **  Could not remove ${USRSBIN_DIR}/kmsgsd!!!\n";
        unlink "${USRSBIN_DIR}/diskmond"   or
            warn " **  Could not remove ${USRSBIN_DIR}/diskmond!!!\n";
    }
    if (-e "${INIT_DIR}/psad") {
        print " .. Removing ${INIT_DIR}/psad\n";
        unlink "${INIT_DIR}/psad";
    }
    if (-e "${PERL_INSTALL_DIR}/Psad.pm") {
        print " ----  Removing ${PERL_INSTALL_DIR}/Psad.pm  ----\n";
        unlink "${PERL_INSTALL_DIR}/Psad.pm";
    }
    if (-d $PSAD_CONFDIR) {
        print " .. Removing configuration directory: $PSAD_CONFDIR\n";
        rmtree($PSAD_CONFDIR, 1, 0);
    }
    if (-d $PSAD_DIR) {
        print " .. Removing logging directory: $PSAD_DIR\n";
        rmtree($PSAD_DIR, 1, 0);
    }
    if (-e $PSAD_FIFO) {
        print " .. Removing named pipe: $PSAD_FIFO\n";
        unlink $PSAD_FIFO;
    }
    if (-e $WHOIS_PSAD) {
        print " .. Removing $WHOIS_PSAD\n";
        unlink $WHOIS_PSAD;
    }
    if (-d $VARLIBDIR) {
        print " .. Removing $VARLIBDIR\n";
        rmtree $VARLIBDIR;
    }
    if (-d $RUNDIR) {
        print " .. Removing $RUNDIR";
        rmtree $RUNDIR;
    }
    if (-d $LIBDIR) {
        print " .. Removing $LIBDIR";
        rmtree $LIBDIR;
    }
    print " .. Restoring /etc/syslog.conf.orig -> /etc/syslog.conf\n";
    if (-e '/etc/syslog.conf.orig') {
        move('/etc/syslog.conf.orig', '/etc/syslog.conf');
    } else {
        print wrap('', $SUB_TAB, " .. /etc/syslog.conf.orig does not exist. " .
            " Editing /etc/syslog.conf directly.\n");
        open ESYS, '< /etc/syslog.conf' or
            die " **  Unable to open /etc/syslog.conf: $!\n";
        my @sys = <ESYS>;
        close ESYS;
        open CSYS, '> /etc/syslog.conf';
            for my $line (@sys) {
            chomp $line;
            ### don't print the psadfifo line
            print CSYS "$line\n" if ($line !~ /psadfifo/);
        }
        close CSYS;
    }
    print " .. Restarting syslog.\n";
    system "$Cmds{'killall'} -HUP syslogd";
    print "\n";
    print " .. Psad has been uninstalled!\n";

    return;
}

sub append_fifo_syslog_ng() {
    &logr(' .. Modifying /etc/syslog-ng/syslog-ng.conf to write kern.info ' .
        "messages to $PSAD_FIFO\n");
    unless (-e '/etc/syslog-ng/syslog-ng.conf.orig') {
        copy '/etc/syslog-ng/syslog-ng.conf',
            '/etc/syslog-ng/syslog-ng.conf.orig';
    }
    &archive('/etc/syslog-ng/syslog-ng.conf');
    open RS, '< /etc/syslog-ng/syslog-ng.conf' or
        die " **  Unable to open /etc/syslog-ng/syslog-ng.conf: $!\n";
    my @slines = <RS>;
    close RS;

    my $found_fifo = 0;
    for my $line (@slines) {
        $found_fifo = 1 if ($line =~ /psadfifo/);
    }

    unless ($found_fifo) {
        open SYSLOGNG, '>> /etc/syslog-ng/syslog-ng.conf' or
            die " ** Unable to open /etc/syslog-ng/syslog-ng.conf: $!\n";
        print SYSLOGNG "\n";
        print SYSLOGNG "destination psadpipe { pipe(\"/var/run/psadfifo\"); };\n";
        print SYSLOGNG "filter f_kerninfo { facility(kern) and level(info); };\n";
        print SYSLOGNG "log { source(src); filter(f_kerninfo); destination(psadpipe); };\n";
        close SYSLOGNG;
    }
    return;
}

sub append_fifo_syslog() {
    &logr(' .. Modifying /etc/syslog.conf to write kern.info ' .
        "messages to $PSAD_FIFO\n");
    unless (-e '/etc/syslog.conf.orig') {
        copy '/etc/syslog.conf', '/etc/syslog.conf.orig';
    }
    &archive('/etc/syslog.conf');
    open RS, '< /etc/syslog.conf' or
        die " **  Unable to open /etc/syslog.conf: $!\n";
    my @slines = <RS>;
    close RS;
    open SYSLOG, '> /etc/syslog.conf' or
        die " **  Unable to open /etc/syslog.conf: $!\n";
    for my $line (@slines) {
        unless ($line =~ /psadfifo/) {
            print SYSLOG $line;
        }
    }
    print SYSLOG '### Send kern.info messages to psadfifo for ' .
        "analysis by kmsgsd\n";
    ### reinstate kernel logging to our named pipe
    print SYSLOG "kern.info\t\t|$PSAD_FIFO\n";
    close SYSLOG;
    return;
}

sub hup_syslog() {
    my @ps_out = `$Cmds{'ps'} -auxww`;
    for my $line (@ps_out) {
        ### root  416  0.0  0.3  1476  624 ?  S  10:11   0:00 syslogd -m 0
        if ($line =~ /^\S+\s+(\d+)(?:\s+\S+){8}\s+syslog/) {
            kill 1, $1;  ### "kill -l" => signal 1 = HUP
        }
    }
    return;
}

sub test_syslog_config() {
    my %used_ports;

    ### first find an unused high tcp port to use for testing
    my @netstat_out = `$Cmds{'netstat'} -an`;

    for my $line (@netstat_out) {
        chomp $line;
        if ($line =~ m/^\s*tcp\s+\d+\s+\d+\s+\S+:(\d+)\s/) {
            ### $1 == protocol (tcp/udp), $2 == port number
            $used_ports{$1} = '';
        }
    }

    ### get the first unused high tcp port greater than 5000
    my $test_port = 5000;
    $test_port++ while defined $used_ports{$test_port};

    ### make sure we can see the loopback interface with
    ### ifconfig
    my @if_out = `$Cmds{'ifconfig'} lo`;

    unless (@if_out) {
        &logr(" ** Could not see the loopback interface " .
            "with ifconfig.\n         Hoping syslog reconfig " .
            "will work anyway.\n");
        return;
    }

    my $lo_ip = '127.0.0.1';
    for my $line (@if_out) {
        if ($line =~ /inet\s+addr:(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s/) {
            $lo_ip = $1;  ### this should always be 127.0.0.1
        }
    }

    ### remove any "test_DROP" lines from fwdata before
    ### seeing if new ones can be written
    &scrub_fwdata();

    my $start_kmsgsd = 1;
    if (-e "${RUNDIR}/kmsgsd.pid") {
        if (open PID, "< ${RUNDIR}/kmsgsd.pid") {
            my $pid = <PID>;
            close PID;
            chomp $pid;
            if (kill 0, $pid) {  ### kmsgsd is already running
                $start_kmsgsd = 0;
            }
        }
    }
    if ($start_kmsgsd) {
        ### briefly start kmsgsd just long enough to test syslog
        ### with a packet to port 5000 (or higher).
        unless (((system "${USRSBIN_DIR}/kmsgsd")>>8) == 0) {
            &logr(" ** Could not start kmsgsd to test syslog.\n" .
                "         Send email to Michael Rash " .
                "(mbr\@cipherdyne.com)\n");
            return;
        }
    }

    ### insert a rule to deny traffic to the loopback
    ### interface on $test_port
    system "$Cmds{'iptables'} -I INPUT 1 -i lo -p tcp --dport " .
        "$test_port -j LOG --log-prefix \"test_DROP \"";

    open FWDATA, "${PSAD_DIR}/fwdata" or
        die " ** Could not open ${PSAD_DIR}/fwdata: $!";

    ### try to connect to $test_port to generate an iptables
    ### drop message.  Note that since nothing is listening on
    ### the port we will immediately receive a tcp reset.
    my $sock = new IO::Socket::INET(
        'PeerAddr' => $lo_ip,
        'PeerPort' => $test_port,
        'Proto'    => 'tcp',
        'Timeout'  => 5
    );

    ### sleep to give kmsgsd a chance to pick up the packet
    ### log message from syslog
    sleep 2;
    my $found = 0;
    my @pkts = <FWDATA>;
    close FWDATA;
    for my $pkt (@pkts) {
        $found = 1 if $pkt =~ /test_DROP/;
    }

    ### remove the testing firewall rule
    system "$Cmds{'iptables'} -D INPUT 1";

    ### remove the any new test_DROP lines we just created
    &scrub_fwdata();

    if ($found) {
        &logr(" .. Successful syslog reconfiguration.\n");
    } else {
        &logr(" ** unsuccessful syslog reconfiguration.\n");
        &logr("         Consult the psad man page for the basic " .
            "syslog requirement to get psad to work.\n");
    }

    if ($start_kmsgsd && -e "${RUNDIR}/kmsgsd.pid") {
        open PID, "${RUNDIR}/kmsgsd.pid" or return;
        my $pid = <PID>;
        close PID;
        chomp $pid;
        if (kill 0, $pid) {
            kill 9, $pid;
        }
    }
    return;
}

sub scrub_fwdata() {
    open SCRUB, "< ${PSAD_DIR}/fwdata" or
        die " ** Could not open ${PSAD_DIR}/fwdata: $!";
    my @lines = <SCRUB>;
    close SCRUB;

    open SCRUB, "> ${PSAD_DIR}/fwdata" or
        die " ** Could not open ${PSAD_DIR}/fwdata: $!";
    for my $line (@lines) {
        print SCRUB $line unless $line =~ /test_DROP/;
    }
    close SCRUB;
    return;
}

sub check_old_psad_installation() {
    my $old_install_dir = '/usr/local/bin';
    if (-e "${old_install_dir}/psad") {
        move "${old_install_dir}/psad", "${USRSBIN_DIR}/psad";
    }
    if (-e "${old_install_dir}/psadwatchd") {
        move "${old_install_dir}/psadwatchd", "${USRSBIN_DIR}/psadwatchd";
    }
    if (-e "${old_install_dir}/diskmond") {
        move "${old_install_dir}/diskmond", "${USRSBIN_DIR}/diskmond";
    }
    if (-e "${old_install_dir}/kmsgsd") {
        move "${old_install_dir}/kmsgsd", "${USRSBIN_DIR}/kmsgsd";
    }
    if (-e "${PSAD_CONFDIR}/psad_signatures.old") {
        unlink "${PSAD_CONFDIR}/psad_signatures.old";
    }
    if (-e "${PSAD_CONFDIR}/psad_auto_ips.old") {
        unlink "${PSAD_CONFDIR}/psad_auto_ips.old";
    }
    if (-e "${PSAD_CONFDIR}/psad.conf.old") {
        unlink "${PSAD_CONFDIR}/psad.conf.old";
    }
    ### Psad.pm will be installed The Right Way using "make"
    unlink "${PERL_INSTALL_DIR}/Psad.pm" if (-e "${PERL_INSTALL_DIR}/Psad.pm");
    if (-e '/var/log/psadfifo') {  ### this is the old psadfifo location
        if (-e "${USRSBIN_DIR}/psad" && system "${USRSBIN_DIR}/psad --Status > /dev/null") {
            ### deal with this later.  The user should be prompted before
            ### the old psadfifo is removed since kmsgsd will have a problem
        } else {
            unlink '/var/log/psadfifo';
        }
    }
    return;
}

sub get_distro() {
    if (-e '/etc/issue') {
        ### Red Hat Linux release 6.2 (Zoot)
        open ISSUE, '< /etc/issue';
        while(<ISSUE>) {
            my $line = $_;
            chomp $line;
            return 'redhat' if ($line =~ /Red\s*Hat/i);
        }
        close ISSUE;
        return 'NA';
    } else {
        return 'NA';
    }
}

sub perms_ownership() {
    my ($file, $perm_value) = @_;
    chmod $perm_value, $file or die " ** Could not " .
        "chmod($perm_value, $file): $!";
    ### chown uid, gid, $file  (root :)
    chown 0, 0, $file or die " ** Could not chown 0,0,$file: $!";
    return;
}

sub get_fw_search_string() {
    print "\n";
    print " .. psad checks the firewall configuration on the underlying machine\n"
        . "     to see if packets will be logged and dropped that have not\n"
        . "     explicitly allowed through.  By default psad looks for the\n"
        . "     string \"DROP\". However, if your particular firewall configuration\n"
        . "     logs blocked packets with the string \"Audit\" for example, psad\n"
        . "     be configured here to look for this string.\n\n";
    my $ans = '';
    while ($ans ne 'y' && $ans ne 'n') {
        print "     Would you like to add a new string that will be used to analyze\n"
            . "     firewall log messages?  (Is it usually safe to say \"n\" here).\n"
            . "     (y/[n])? ";
        $ans = <STDIN>;
        if ($ans eq "\n") {  ### allow the default answer to take over
            $ans = 'n';
        }
        chomp $ans;
    }
    print "\n";
    my $fw_string = '';
    if ($ans eq 'y') {
        &logr("     Enter a string (i.e. \"Audit\"):  ");
        $fw_string = <STDIN>;
        chomp $fw_string;
    }
    return $fw_string;
}

sub query_email() {
    my $filename = 'psad.conf';
    open F, "< ${PSAD_CONFDIR}/psad.conf";
    my @clines = <F>;
    close F;
    my $email_addresses;
    for my $line (@clines) {
        chomp $line;
        if ($line =~ /^\s*EMAIL_ADDRESSES\s+(.+);/) {
            $email_addresses = $1;
            last;
        }
    }
    unless ($email_addresses) {
        return '';
    }
    &logr(" .. psad alerts will be sent to:\n\n");
    &logr("       $email_addresses\n\n");
    my $ans = '';
    while ($ans ne 'y' && $ans ne 'n') {
        &logr(" .. Would you like alerts sent to a different address ([y]/n)?  ");
        $ans = <STDIN>;
        if ($ans eq "\n") {  ### allow the default of "y" to take over
                             ### when just "Enter" is pressed.
            $ans = 'y';
        }
        chomp $ans;
    }
    print "\n";
    if ($ans eq 'y') {
        print "\n";
        &logr(" .. To which email address(es) would you like " .
            "psad alerts to be sent?\n");
        &logr(" .. You can enter as many email addresses as you like " .
            "separated by spaces.\n");
        my $emailstr = '';
        my $correct = 0;
        while (! $correct) {
            print 'Email addresses: ';
            $emailstr = <STDIN>;
            $emailstr =~ s/\,//g;
            chomp $emailstr;
            my @emails = split /\s+/, $emailstr;
            $correct = 1;
            for my $email (@emails) {
                unless ($email =~ /\S+\@\S+/) {
                    $correct = 0;
                }
            }
            $correct = 0 unless @emails;
        }
        return $emailstr;
    } else {
        return '';
    }
    return '';
}

sub put_email() {
    my ($file, $emailstr) = @_;
    chomp $emailstr;
    open RF, "< $file";
    my @lines = <RF>;
    close RF;
    open F, "> $file";
    for my $line (@lines) {
        if ($line =~ /EMAIL_ADDRESSES\s+/) {
            print F "EMAIL_ADDRESSES            $emailstr;\n";
        } else {
            print F $line;
        }
    }
    close F;
    return;
}

sub put_custom_fw_search_str() {
    my ($file, $custom_fw_search) = @_;
    open RF, "< $file";
    my @lines = <RF>;
    close RF;
    open F, "> $file";
    for my $line (@lines) {
        if ($line =~ /^\s*FW_MSG_SEARCH1\s/) {
            print F "FW_MSG_SEARCH1              $custom_fw_search;\n";
        } else {
            print F $line;
        }
    }
    close F;
    return;
}

sub put_string() {
    my ($file, $key, $value) = @_;
    open RF, "< $file";
    my @lines = <RF>;
    close RF;
    open F, "> $file";
    for my $line (@lines) {
        if ($line =~ /^\s*$key\s*.*;/) {
            print F "$key                    $value;\n";
        } else {
            print F $line;
        }
    }
    close F;
    return;
}

sub archive() {
    my $file = shift;
    my ($filename) = ($file =~ m|.*/(.*)|);
    my $targetbase = "${CONF_ARCHIVE}/${filename}.old";
    for (my $i = 4; $i > 1; $i--) {  ### keep five copies of the old config files
        my $oldfile = $targetbase . $i;
        my $newfile = $targetbase . ($i+1);
        if (-e $oldfile) {
            move $oldfile, $newfile;
        }
    }
    if (-e $targetbase) {
        my $newfile = $targetbase . '2';
        move $targetbase, $newfile;
    }
    &logr(" .. Archiving $file -> $targetbase\n");
    copy $file, $targetbase;   ### move $file into the archive directory
    return;
}

sub enable_psad_at_boot() {
    my $distro = shift;
    my $ans = '';
    while ($ans ne 'y' && $ans ne 'n') {
        &logr(" .. Enable psad at boot time ([y]/n)?  ");
        $ans = <STDIN>;
        if ($ans eq "\n") {  ### allow the default of "y" to take over
            $ans = 'y';
        }
        chomp $ans;
    }
    if ($ans eq 'y') {
        if ($distro =~ /redhat/) {
            system "$Cmds{'chkconfig'} --add psad";
        } else {  ### it is a non-redhat distro, try to
                  ### get the runlevel from /etc/inittab
            if ($RUNLEVEL) {
                ### the link already exists, so don't re-create it
                unless (-e "/etc/rc.d/rc${RUNLEVEL}.d/S99psad") {
                    symlink '/etc/rc.d/init.d/psad',
                        "/etc/rc.d/rc${RUNLEVEL}.d/S99psad";
                }
            } elsif (-e '/etc/inittab') {
                open I, '< /etc/inittab';
                my @ilines = <I>;
                close I;
                for my $line (@ilines) {
                    chomp $line;
                    if ($line =~ /^id\:(\d)\:initdefault/) {
                        $RUNLEVEL = $1;
                        last;
                    }
                }
                unless ($RUNLEVEL) {
                    &logr(" **  Could not determine the runlevel.  Set " .
                        "the runlevel\nmanually in the config section of " .
                        "install.pl\n");
                    return;
                }
                ### the link already exists, so don't re-create it
                unless (-e "/etc/rc.d/rc${RUNLEVEL}.d/S99psad") {
                    symlink '/etc/rc.d/init.d/psad',
                        "/etc/rc.d/rc${RUNLEVEL}.d/S99psad";
                }
            } else {
                &logr(" **  /etc/inittab does not exist!  Set the " .
                    "runlevel\nmanually in the config section of " .
                    "install.pl.\n");
                return;
            }
        }
    }
    return;
}

### check paths to commands and attempt to correct if any are wrong.
sub check_commands() {
    my $caller = $0;
    my @path = qw(
        /bin
        /sbin
        /usr/bin
        /usr/sbin
        /usr/local/bin
        /usr/local/sbin
    );
    CMD: for my $cmd (keys %Cmds) {
        unless (-x $Cmds{$cmd}) {
            my $found = 0;
            PATH: for my $dir (@path) {
                if (-x "${dir}/${cmd}") {
                    $Cmds{$cmd} = "${dir}/${cmd}";
                    $found = 1;
                    last PATH;
                }
            }
            unless ($found) {
                next CMD if ($cmd eq 'ipchains' || $cmd eq 'iptables');
                die "\n **  ($caller): Could not find $cmd anywhere!!!  " .
                    "Please edit the config section to include the path to " .
                    "$cmd.\n";
            }
        }
        unless (-x $Cmds{$cmd}) {
            die "\n **  ($caller):  $cmd is located at " .
                "$Cmds{$cmd} but is not executable by uid: $<\n";
        }
    }
    return;
}

sub install_manpage() {
    my $manpage = shift;
    ### remove old man page
    unlink "/usr/local/man/man8/${manpage}" if
        (-e "/usr/local/man/man8/${manpage}");

    ### default location to put the psad man page, but check with
    ### /etc/man.config
    my $mpath = '/usr/share/man/man8';
    if (-e '/etc/man.config') {
        ### prefer to install $manpage in /usr/local/man/man8 if
        ### this directory is configured in /etc/man.config
        open M, '< /etc/man.config' or
            die " ** Could not open /etc/man.config: $!";
        my @lines = <M>;
        close M;
        ### prefer the path "/usr/share/man"
        my $found = 0;
        for my $line (@lines) {
            chomp $line;
            if ($line =~ m|^MANPATH\s+/usr/share/man|) {
                $found = 1;
                last;
            }
        }
        ### try to find "/usr/local/man" if we didn't find /usr/share/man
        unless ($found) {
            for my $line (@lines) {
                chomp $line;
                if ($line =~ m|^MANPATH\s+/usr/local/man|) {
                    $mpath = '/usr/local/man/man8';
                    $found = 1;
                    last;
                }
            }
        }
        ### if we still have not found one of the above man paths,
        ### just select the first one out of /etc/man.config
        unless ($found) {
            for my $line (@lines) {
                chomp $line;
                if ($line =~ m|^MANPATH\s+(\S+)|) {
                    $mpath = $1;
                    last;
                }
            }
        }
    }
    mkdir $mpath, 0755 unless -d $mpath;
    my $mfile = "${mpath}/${manpage}";
    &logr(" .. Installing $manpage man page as $mfile\n");
    copy $manpage, $mfile or die " ** Could not copy $manpage to " .
        "$mfile: $!";
    &perms_ownership($mfile, 0644);
    &logr(" .. Compressing manpage $mfile\n");
    ### remove the old one so gzip doesn't prompt us
    unlink "${mfile}.gz" if -e "${mfile}.gz";
    system "$gzipCmd $mfile";
    return;
}

### logging subroutine that handles multiple filehandles
sub logr() {
    my $msg = shift;
    for my $file (@LOGR_FILES) {
        if ($file eq *STDOUT) {
            if (length($msg) > 72) {
                print STDOUT wrap('', $SUB_TAB, $msg);
            } else {
                print STDOUT $msg;
            }
        } elsif ($file eq *STDERR) {
            if (length($msg) > 72) {
                print STDERR wrap('', $SUB_TAB, $msg);
            } else {
                print STDERR $msg;
            }
        } else {
            open F, ">> $file";
            if (length($msg) > 72) {
                print F wrap('', $SUB_TAB, $msg);
            } else {
                print F $msg;
            }
            close F;
        }
    }
    return;
}

sub usage() {
        my $exitcode = shift;
        print <<_HELP_;

Usage: install.pl [-n] [-u] [-v] [-h]

    -n  --no-preserve   - disable preservation of old configs.
    -u  --uninstall     - uninstall psad.
    -v  --verbose       - verbose mode.
    -h  --help          - prints this help message.

_HELP_
        exit $exitcode;
}
