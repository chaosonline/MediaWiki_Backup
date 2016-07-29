#!/bin/bash
#
# MediaWiki backup and archiving script for installations on Linux using MySQL.
#
# https://github.com/samwilson/MediaWiki_Backup
#
# Copyright Sam Wilson 2013 CC-BY-SA
# http://creativecommons.org/licenses/by-sa/3.0/au/
#


################################################################################
## Output command usage
function usage {
    local NAME=$(basename $0)
    echo "Usage: $NAME -d dir -w dir [-s]"
    echo "       -d <dir>    Path to the desination backup directory. Required."
    echo "       -w <dir>    Path to the wiki installation directory. Required."
    echo "       -s          Create a single archive file instead of 3"
    echo "                   (images, database, and XML). Optional."
    echo "       -p <prefix> Prefix for the resulting archive file name(s)."
    echo "                   Defaults to the current date in Y-m-d format. Optional."
}

################################################################################
## Get and validate CLI options
function get_options {
    while getopts 'd:w:p:s' OPT; do
        case $OPT in
            d) BACKUP_DIR=$OPTARG;;
            w) INSTALL_DIR=$OPTARG;;
            p) PREFIX=$OPTARG;;
            s) SINGLE_ARCHIVE=true;;
        esac
    done

    ## Check wiki installation directory
    if [ -z "$INSTALL_DIR" ]; then
        echo "Please specify the wiki directory with -w" 1>&2
        usage; exit 1;
    fi
    if [ ! -f "$INSTALL_DIR/LocalSettings.php" ]; then
        echo "No LocalSettings.php found in $INSTALL_DIR" 1>&2
        exit 1;
    fi
    INSTALL_DIR=$(cd $INSTALL_DIR; pwd -P)
    echo "Backing up wiki installed in $INSTALL_DIR"

    ## Check backup destination directory
    if [ -z "$BACKUP_DIR" ]; then
        echo "Please provide a backup directory with -d" 1>&2
        usage; exit 1;
    fi
    if [ ! -d "$BACKUP_DIR" ]; then
        mkdir --parents $BACKUP_DIR;
        if [ ! -d "$BACKUP_DIR" ]; then
            echo -n "Backup directory $BACKUP_DIR does not exist" 1>&2
            echo " and could not be created" 1>&2
            exit 1;
        fi
    fi
    BACKUP_DIR=$(cd "$BACKUP_DIR"; pwd -P)
    echo "Backing up to $BACKUP_DIR"

    ## Check and set the archive name prefix
    if [ -z "$PREFIX" ]; then
        PREFIX=$(date +%Y-%m-%d)
    fi

    ## Check whether a single archive file should be created
    SINGLE_ARCHIVE=false
    if [ -z $SINGLE_ARCHIVE ]; then
        SINGLE_ARCHIVE=true
    fi

}

################################################################################
## Parse required values out of LocalSetttings.php
function get_localsettings_vars {
    LOCALSETTINGS="$INSTALL_DIR/LocalSettings.php"

    DB_HOST=`grep '^\$wgDBserver' $LOCALSETTINGS | cut -d\" -f2`
    DB_NAME=`grep '^\$wgDBname' $LOCALSETTINGS  | cut -d\" -f2`
    DB_USER=`grep '^\$wgDBuser' $LOCALSETTINGS  | cut -d\" -f2`
    DB_PASS=`grep '^\$wgDBpassword' $LOCALSETTINGS  | cut -d\" -f2`
    echo "Logging in as $DB_USER to $DB_HOST to backup $DB_NAME"

    # Try to extract default character set from LocalSettings.php
    # but default to binary
    DBTableOptions=$(grep '$wgDBTableOptions' $LOCALSETTINGS)
    CHARSET=$(echo $DBTableOptions | sed -E 's/.*CHARSET=([^"]*).*/\1/')
    if [ -z $CHARSET ]; then
        CHARSET="binary"
    fi

    echo "Character set in use: $CHARSET"
}

################################################################################
## Add $wgReadOnly to LocalSettings.php
## Kudos to http://www.mediawiki.org/wiki/User:Megam0rf/WikiBackup
function toggle_read_only {
    local MSG="\$wgReadOnly = 'Backup in progress.';"
    local LOCALSETTINGS="$INSTALL_DIR/LocalSettings.php"

    # Don't do anything if we can't write to LocalSettings.php
    if [ ! -w "$LOCALSETTINGS" ]; then
        return 0
    fi

    # If already read-only
    grep "$MSG" "$LOCALSETTINGS" > /dev/null
    if [ $? -ne 0 ]; then

        echo "Entering read-only mode"
        grep "?>" "$LOCALSETTINGS" > /dev/null
        if [ $? -eq 0 ];
        then
            sed -i "s/?>/\n$MSG/ig" "$LOCALSETTINGS"
        else
            echo "$MSG" >> "$LOCALSETTINGS"
        fi 

    # Remove read-only message
    else

        echo "Returning to write mode"
        sed -i "s/$MSG//ig" "$LOCALSETTINGS"

    fi
}

################################################################################
## Dump database to SQL
## Kudos to https://github.com/milkmiruku/backup-mediawiki
function export_sql {
    SQLFILE=$BACKUP_PREFIX"-database.sql.gz"
    echo "Dumping database to $SQLFILE"
    nice -n 19 mysqldump --single-transaction \
        --default-character-set=$CHARSET \
        --host=$DB_HOST \
        --user=$DB_USER \
        --password=$DB_PASS \
        $DB_NAME | gzip -9 > $SQLFILE

    # Ensure dump worked
    MySQL_RET_CODE=$?
    if [ $MySQL_RET_CODE -ne 0 ]; then
        ERR_NUM=3
        echo "MySQL Dump failed! (return code of MySQL: $MySQL_RET_CODE)" 1>&2
        exit $ERR_NUM
    fi
}

################################################################################
## XML
## Kudos to http://brightbyte.de/page/MediaWiki_backup
function export_xml {
    XML_DUMP=$BACKUP_PREFIX"-pages.xml.gz"
    echo "Exporting XML to $XML_DUMP"
    cd "$INSTALL_DIR/maintenance"
    php -d error_reporting=E_ERROR dumpBackup.php \
        --conf="$INSTALL_DIR/LocalSettings.php" --quiet --full \
        | gzip -9 > "$XML_DUMP"
}

################################################################################
## Export the images directory
function export_images {
    IMG_BACKUP=$BACKUP_PREFIX"-images.tar.gz"
    echo "Compressing images to $IMG_BACKUP"
    cd "$INSTALL_DIR"
    tar --exclude-vcs -zcf "$IMG_BACKUP" images
}

################################################################################
## Combine the three export files into one and delete the three
function combine_archives {
    FULL_DUMP=$BACKUP_PREFIX"-backup.tar.gz";
    echo "Creating full backup archive: $FULL_DUMP"
    #DUMPS="$BACKUP_PREFIX""-database.sql.gz" 
    #    $BACKUP_PREFIX"-pages.xml.gz"
    #    $BACKUP_PREFIX"-images.tar.gz"
    cd "$BACKUP_DIR"
    tar -zcf "$FULL_DUMP" "$PREFIX"*.gz
}

################################################################################
## Main

# Preparation
get_options $@
get_localsettings_vars
toggle_read_only

# Exports
BACKUP_PREFIX=$BACKUP_DIR/$PREFIX
export_sql
export_xml
export_images

toggle_read_only

if [ "$SINGLE_ARCHIVE" = true ]; then
    combine_archives
fi

## End main
################################################################################

# eh? what's this do? exec > /dev/null
