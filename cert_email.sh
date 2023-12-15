#!/bin/bash

## Script to email IPA certificates when renewed.
#
# ipa-getcert can start tasks through pre and post-save scripts.
# This script will flag which certificates should be emailed to a given address.
# It's intended to be run by ipa-getcert post-save on certificate renewal. Adding
# The certificates to be sent to the configuration file.
#
# When called with the `-s` flag (for example from cron), it will email certificates
# To the recipients configured in the configuration file.
#
# When run manually, the email can be sent containing all certificates irrespective
# of the certificates flagged for sending in the configuration file.
# 
# A cronjob should be used to email the certificates together rather than individually.
# The cronjob frequency will dictate when certificates will be sent.

## Help for config file format
show_conf() {
cat << EOF
Example configuration file:

  # Email certificates to (space-delimited array)
  TO=(name1@domain.com name2@domain.com)
  # Email body header and footer in printf format.
  BODY_HEADER="Dear Recipient,\n\nPlease replace the certificate(s) on the following devices:\n"
  BODY_FOOTER="\n-- \nRegards,\nSender"
  SENDER="Admin <admin@domain.com>"
  # Obligatory: List certs as a space-delimited array.
  CERTS=(a.domain.com b.domain.com c.domain.com)
  # Certificates renewed and ready for emailing.
  # Can be used to selectively send certificates by manually editing the array.
  RENEWED=()
EOF
}

## Paths & variables
CNF_PATH="/etc/ipa/cert_email"
CERT_PATH="/etc/ssl/certs"

## Usage info
show_help() {
cat << EOF
Usage: ${0##*/} [-h -c <CERT_CN> -s -a -q] <config file>
This script flags certificates issued by ipa-getcert for emailing out.

    <config file>   Configuration file. If no path is given, $CNF_PATH will be assumed.
    -c <CERT_CN>    (cn)    Certificate Common Name.
    -s              (send)  Send email(s).
    -a              (all)   Send all certificates.
    -q              (quiet) Don't complain about no renewed certificates, useful for cronjobs.
    -h              (help)  Display this help and exit.
EOF
}

## Fixed variables
CERTS=()
OPTIND=1

## Read/interpret optional arguments
while getopts c:saqh opt; do
    case $opt in
        c)  CN=$OPTARG
            ;;
        s)  SEND="yes"
            ;;
        a)  ALL="yes"
            ;;
        q)  QUIET="yes"
            ;;
        *)  show_help >&2
            exit 1
            ;;
    esac
done
shift "$((OPTIND-1))"   # Discard the options and sentinel --

# This script must be run as root
if [ "$EUID" -ne 0 ]; then
    echo "WARNING: Please run as root, aborting."
    exit 1
fi

# Check if s-nail is installed
if [[ "$SEND" == "yes" ]] && ! which s-nail &> /dev/null; then
    echo "ERROR: s-nail not found, aborting."
    exit 1
fi

# Check minimum options
if [[ -z $CN ]] && [[ -z $SEND ]]; then
    echo "ERROR: Minimum requirement not met. At least one of these options must be given: -c or -s."
    exit 1
fi

# Verify the configuration file
if [[ -z "$@" ]]; then
    printf "ERROR: No configuration file provided."
    show_help >&2
    exit 1
elif [[ -f "$@" ]]; then
    CNF="$@"
    #echo "Config file found: $CNF"
elif [[ -f "${CNF_PATH}/$@" ]]; then
    CNF="${CNF_PATH}/$@"
    #echo "Config file found: $CNF"
else    
    echo "ERROR: config file not found: $@"
    show_help >&2
    exit 1
fi
source "$CNF"
[[ "$QUIET" == "yes" ]] || echo "Config read from: $CNF"
if [ ${#CERTS[@]} -eq 0 ]; then
    printf "ERROR: No array of certs found in config file: %s" "$CNF"
    show_conf >&2
    exit 1
fi
# Set defaults in case not parsed or missing from config
: ${SEND:="no"}
: ${ALL:="no"}
: ${BODY_HEADER:="Dear recipient,\n\nPlease replace the following certificates:\n"}
: ${BODY_FOOTER:="\n-- \nRegards,\n$(hostname)"}
: ${SENDER:="cert_email.sh <$(id -un)@$(hostname)>"}

# Test if at least one email address is configured if the send flag is set
if [[ "$SEND" == "yes" ]]; then
    if [ ${#TO[@]} -eq 0 ]; then
        printf "ERROR: No email address(es) found in config file: %s" "$CNF"
        show_conf >&2
        exit 1
    fi
    SEND_TO=()
    for i in "${!TO[@]}"; do
        # Grab the base address if 'pretty' formatting is given.
        addr=$(echo "${TO[$i]}" | cut -d "<" -f2 | cut -d ">" -f1)
        if [[ "$addr" =~ ^.+@.+\.[[:alpha:]]{2,}$ ]]; then
            # Test if the domain has an MX record
            if host -t MX ${addr##*@} &> /dev/null; then
                # An MX record is found, use it.
                SEND_TO+=($addr)
            else
                # Ignore invalid addresses
                printf "WARNING: %s doesn't have an MX record, skipping this email address.\n" "$addr"
            fi
        else
            printf "WARNING: Invalid email address configured: %s\n" "$addr"
        fi
    done
    if [ ${#SEND_TO[@]} -eq 0 ]; then
        printf "ERROR: No valid email addresses found in configuration file: %s\n" "$CNF"
        printf "WARNING: No email will be sent.\n"
        SEND="no"
    fi
fi

# Take action on a parsed Common Name
if [[ -n $CN ]] && [[ "$SEND" == "yes" ]]; then
    # Take action on a parsed Common Name, send email now.
    SUBJECT="New certificate for device: $CN"
    # Check if certificate file exists
    CRT_FILE="${CERT_PATH}/${CN}.crt"
    if [[ ! -f "$CRT_FILE" ]]; then
        printf "ERROR: Certificate file not found: %s\n" "$CRT_FILE"
        exit 2
    fi
    # Zip certificate
    rm -f "/tmp/${CN}.zip" # Ensure the zip file is empty
    zip -q -j "/tmp/${CN}.zip" "$CRT_FILE"
    # Send email with attached zip file
    printf "$BODY_HEADER\n - $CN\n$BODY_FOOTER\n" | s-nail -a "/tmp/${CN}.zip" -s "$SUBJECT" -r "$SENDER" "${SEND_TO[@]}"
    rm "/tmp/${CN}.zip" # Clean up
    printf 'SUCCESS: Email with certificate for domain (%s) sent to: %s\n' "$CN" "${SEND_TO[@]}"
elif [[ -n $CN ]]; then
    # Take action on a parsed Common Name, add it to the array in the config file.
    if ! grep -q '^\s*RENEWED=(' "$CNF"; then
        echo "RENEWED=($CN)" >> "$CNF"
    else
        sed -i "s/RENEWED=(/RENEWED=($CN /g" "$CNF"
    fi
    printf 'SUCCESS: certificate for domain (%s) added to RENEWED list in config file: %s\n' "$CN" "$CNF"
elif [[ "$SEND" == "yes" ]]; then
    # Email out the pending certificates as per the RENEWED array in the config file.
    if [[ "$ALL" == "yes" ]]; then
        # Ignore RENEWED list of certs read from config
        RENEWED=("${CERTS[@]}")
    fi
    # Verify RENEWED is not empty
    if [ ${#RENEWED[@]} -eq 0 ]; then
        if [[ "$QUIET" == "yes" ]]; then
            # Silently exit
            exit
        else
            printf 'WARNING: No renewed certificates found in configuration file: %s\n' "$CNF"
            printf '         Check the configuration file or use the (-a) flag to send all certificates.\n'
            exit 2
        fi
    fi
    SUBJECT="New certificates for devices"
    # Check if certificate files exist.
    ZIP_FILES=()
    SEND_CN=()
    for cn in ${RENEWED[@]}; do
        CRT_FILE="${CERT_PATH}/${cn}.crt"
        if [[ ! -f "$CRT_FILE" ]]; then
            printf 'WARNING: Certificate file not found: %s. Not including in email.\n' "$CRT_FILE"
        else
            ZIP_FILES+=($CRT_FILE)
            SEND_CN+=($cn)
        fi
    done
    # Zip certificates
    if [ ${#ZIP_FILES[@]} -eq 0 ]; then
        printf 'ERROR: No certificate files found to send, aborting.\n'
        exit 3
    fi
    rm -f "/tmp/cert_email.zip" # Ensure the zip file is empty
    zip -q -j "/tmp/cert_email.zip" "${ZIP_FILES[@]}"
    # Send email with attached zip file
    (printf "$BODY_HEADER\n"; printf ' - %s\n' "${SEND_CN[@]}"; printf "\n$BODY_FOOTER\n") | s-nail -a "/tmp/cert_email.zip" -s "$SUBJECT" -r "$SENDER" "${SEND_TO[@]}"
    rm "/tmp/cert_email.zip" # Clean up
    # Empty the RENEWED array in the config file
    sed -i -E 's/^\w*RENEWED=(.+)\w*$/RENEWED=()/g' "$CNF"
    printf 'SUCCESS: Email sent to: %s\nContaining these certificates:\n' "$(printf "'%s' " "${SEND_TO[@]}")"
    printf ' - %s\n' "${RENEWED[@]}"
    if [[ ! "$ALL" == "yes" ]]; then
        printf 'RENEWED certificate list cleared in config file: %s\n' "$CNF"
    fi
fi
