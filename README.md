# getcerts_email

Automate sending certificates via email upon issuing and renewal by ipa-getcert

This script was written to automate the sending of certificates via email. Note that only the public certificate is emailed, a private key must never be sent via email❗

## Prerequisites

`s-nail`, `mailx` works but gets troublesome when sending email body and attachments at the same time and apparently, it hasn't had an update in years.

`sudo apt install s-nail` 

Deploy the script to a host which can send external emails, query DNS MX records and is enrolled into FreeIPA (`freeipa-client`).

To issue certificates for a different host, the hosts and HTTP service principals must be added to IPA, both set to be managed by the ipa client that will request and monitor these certificates.

- Hosts
  - server1.example.local : 192.168.0.1
  - server1.example.local : 192.168.0.2
- Service principals
  - HTTP/server1.example.local@EXAMPLE.LOCAL
  - HTTP/server2.example.local@EXAMPLE.LOCAL
- Managed by
  - server3.example.local (same for all hosts and HTTP service principals)

## Installation

Put the `cert_email.sh` file in `/usr/local/bin`. and ensure it's executable:

`sudo cp cert_email.sh /usr/local/bin/`  
`sudo chmod +x /usr/local/bin/cert_email.sh` 

## Configuration

A configuration file is required. Create the folder for the configuration file(s): 

`sudo mkdir /etc/ipa/cert_email` 

Create the configuration file: 

`sudo vi sudo vi /etc/ipa/cert_email/your-service.conf` 

```text
# Automated emails with renewed certificates for your service with no API

# Email certificates to (space-delimited array)
TO=(somebody@domain.com)
# Email body header and footer in printf format.
BODY_HEADER="Dear recipient,\n\nPlease replace the certificate(s) on the following devices:\n"
BODY_FOOTER="\n-- \nRegards,\nA poor admin without access"
SENDER="Poor Admin <admin@domain.com>"

# Obligatory: List certs as a space-delimited array.
CERTS=(server1.example.local server2.example.local)

# Certificates renewed and ready for emailing.
# Can be used to selectively send certificates by manually editing the array.
RENEWED=()
```

## ipa-getcert post-save usage

The same script can either immediately send an email or add the certificate to the configuration file for later sending by a cronjob.

To send the certificate immediately, use the following commands: 

`service="service1.example.local"`  
`sudo ipa-getcert request -N ${service} -K HTTP/${service} -k /etc/ssl/private/${service}.key -f /etc/ssl/certs/${service}.crt -D ${service} -A $(host -t A ${service} | awk 'NF>1{print $NF}') -C "/usr/local/bin/cert_email.sh -s -c ${service} /etc/ipa/cert_email/your-service.conf"` 

To send the certificate later, use the following commands: 

`service="service1.example.local"`  
`sudo ipa-getcert request -N ${service} -K HTTP/${service} -k /etc/ssl/private/${service}.key -f /etc/ssl/certs/${service}.crt -D ${service} -A $(host -t A ${service} | awk 'NF>1{print $NF}') -C "/usr/local/bin/cert_email.sh -c ${service} /etc/ipa/cert_email/your-service.conf"` 

```text
user@host:~$ sudo ipa-getcert request -N ${service} -K HTTP/${service} -k /etc/ssl/private/${service}.key -f /etc/ssl/certs/${service}.crt -D ${service} -A $(host -t A ${service} | awk 'NF>1{print $NF}') -C "/usr/local/bin/cert_email.sh -c ${service} /etc/ipa/cert_email/your-service.conf"
New signing request "20231214125449" added.
user@host:~$ sudo ipa-getcert list -i 20231214125449
Number of certificates and requests being tracked: 20.
Request ID '20231214125449':
        status: MONITORING
        stuck: no
        key pair storage: type=FILE,location='/etc/ssl/private/service1.example.local.key'
        certificate: type=FILE,location='/etc/ssl/certs/service1.example.local.crt'
        CA: IPA
        issuer: CN=Certificate Authority,O=EXAMPLE.LOCAL
        subject: CN=service1.example.local,O=EXAMPLE.LOCAL
        expires: 2025-12-14 13:54:50 CET
        dns: service1.example.local
        principal name: HTTP/service1.example.local@EXAMPLE.LOCAL
        key usage: digitalSignature,nonRepudiation,keyEncipherment,dataEncipherment
        eku: id-kp-serverAuth,id-kp-clientAuth
        pre-save command:
        post-save command: /usr/local/bin/cert_email.sh -c service1.example.local /etc/ipa/cert_email/your-service.conf
        track: yes
        auto-renew: yes

user@host:~$ sudo grep RENEWED /etc/ipa/cert_email/your-service.conf
RENEWED=(service1.example.local )

user@host:~$ service="service2.example.local"
user@host:~$ sudo ipa-getcert request -N ${service} -K HTTP/${service} -k /etc/ssl/private/${service}.key -f /etc/ssl/certs/${service}.crt -D ${service} -A $(host -t A ${service} | awk 'NF>1{print $NF}') -C "/usr/local/bin/cert_email.sh -c ${service} /etc/ipa/cert_email/your-service.conf"
New signing request "20231214125659" added.
user@host:~$ sudo grep RENEWED /etc/ipa/cert_email/your-service.conf
RENEWED=(service1.example.local service2.example.local )
```

## Cron

To email out the certificates together, rather than individually, create a cronjob which runs at the desired interval.

`sudo vi /etc/cron.d/cert_email.your-service` 

```text
PATH=/bin:/usr/bin:/sbin:/usr/sbin
MAILTO=admin@domain.com
MAILFROM=host+cron@domain.com

# Weekly check for renewed your-service certificates (at 04:15 on Monday mornings)
15 4 * * 1 root /usr/local/bin/cert_email.sh -s -q /etc/ipa/cert_email/your-service.conf
```

## Testing

### Sending emails

Before the certificates were created: 

```text
user@host:~$ cert_email.sh
WARNING: Please run as root, aborting.

user@host:~$ sudo /usr/local/bin/cert_email.sh
ERROR: Minimum requirement not met. At least one of these options must be given: -c or -s.

user@host:~$ /usr/local/bin/cert_email.sh -s
ERROR: No configuration file provided.Usage: cert_email.sh [-h -c <CERT_CN> -s -a] <config file>
This script flags certificates issued by ipa-getcert for emailing out.

    <config file>   Configuration file. If no path is given, /etc/ipa/cert_email will be assumed.
    -c <CERT_CN>    (cn)    Certificate Common Name.
    -s              (send)  Send email(s).
    -a              (all)   Send all certificates.
    -q              (quiet) Don't complain about no renewed certificates, useful for cronjobs.
    -h              (help)  Display this help and exit.

user@host:~$ sudo /usr/local/bin/cert_email.sh -s /etc/ipa/cert_email/your-service.conf
Config read from: /etc/ipa/cert_email/your-service.conf
WARNING: No renewed certificates found in configuration file: /etc/ipa/cert_email/your-service.conf
         Check the configuration file or use the (-a) flag to send all certificates.

user@host:~$ sudo /usr/local/bin/cert_email.sh -s -a /etc/ipa/cert_email/your-service.conf
Config read from: /etc/ipa/cert_email/your-service.conf
WARNING: Certificate file not found: /etc/ssl/certs/server1.example.local.crt. Not including in email.
WARNING: Certificate file not found: /etc/ssl/certs/server2.example.local.crt. Not including in email.
ERROR: No certificate files found to send, aborting.
```

Some certificates are needed before they can be emailed out!

After the certificates were created: 

```text
user@host:~$ sudo /usr/local/bin/cert_email.sh -s -a /etc/ipa/cert_email/your-service.conf
Config read from: /etc/ipa/cert_email/your-service.conf
SUCCESS: Email sent to: admin@domain.com
Containing these certificates:
 - server1.example.local
 - server2.example.local

user@host:~$ sudo /usr/local/bin/cert_email.sh -s /etc/ipa/cert_email/your-service.conf
Config read from: /etc/ipa/cert_email/your-service.conf
SUCCESS: Email sent to: admin@domain.com
Containing these certificates:
 - server2.example.local
RENEWED certificate list cleared in config file: /etc/ipa/cert_email/your-service.conf
```

## Don't forget

Whoever you're sending the certificate to, will also need the private key(s). Private keys don't typically change very often, so it's better to send them manually, preferably encrypted.
