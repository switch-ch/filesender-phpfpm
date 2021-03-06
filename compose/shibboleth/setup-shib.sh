#!/bin/bash
#set -x

REQUIRED="hostname perl sed openssl docker-compose nc curl"

for UTILITY in $REQUIRED; do
  WHICH_CMD="`which $UTILITY`"

  if [ "$WHICH_CMD" = "" ]; then
    echo "ERROR: please install cmd line utility: $UTILITY"
    echo "ERROR: $REQUIRED are needed."  
    exit 1
  fi
done

# Make sure we are running from the setup-shib.sh directory
SETUP_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
while [ ! -d "$SETUP_DIR/../shibboleth/template" ]; do
    SETUP_DIR="$( cd $SETUP_DIR/.. && pwd )"
done

echo "WORKINGDIR: $SETUP_DIR"
cd $SETUP_DIR

GIVENIP=$1
HOSTIP=$1

if [ "$HOSTIP" = "" ]; then
  HOSTIP=`hostname -I 2>&1 | perl -ne '@ip = grep( !/^(192.168|10|172.[1-3]\d)./, split(/\s/)); print join("|",@ip)'`

OCTETS=`echo -n $HOSTIP | sed -e 's|\.|#|g' | perl -ne '@valid = grep(/\d+/,split(/#/)); print scalar(@valid)'`

echo "CALCULATED $HOSTIP has $OCTETS parts"

# Validate 
if [ "$OCTETS" != "4" ]; then
   echo "ERROR: was not able to use a single IP to setup with."
   echo "ERROR: Please rerun passing in the public IP to use."
   echo "ERROR: Example: ./setup-shib.sh <your_public_ip>"
   exit 1
fi
fi

METADATA_URL="https://$HOSTIP/Shibboleth.sso/Metadata"
METADATA_FILE="docker-filesender-phpfpm-shibboleth-$HOSTIP-metadata.xml"

if [ ! -f "$METADATA_FILE" ]; then

echo "STOPPING any docker-compose created images"
docker-compose rm -fsv
echo "y" | docker volume prune

DEVICE=$HOSTIP
SUBJECT="/C=FC/postalCode=FakeZip/ST=FakeState/L=FakeCity/streetAddress=FakeStreet/O=FakeOrganization/OU=FakeDepartment/CN=${DEVICE}"
DAYS=1095   # 3 * 365

function create_self_signed_cert {

  local DESTDIR=$1
  local CERT_KEY=$2
  local CERT_CSR=$3
  local CERT_SIGNED=$4

  echo "GENERATING ssl self-signed cert files"
  echo "   $DESTDIR/$CERT_SIGNED"
  echo "   $DESTDIR/$CERT_CSR"
  echo "   $DESTDIR/$CERT_KEY"
  
  # Create private key $CERT_KEY and csr $CERT_CSR:
  cd $DESTDIR
  openssl req -nodes -newkey rsa:2048 -keyout $CERT_KEY -subj "${SUBJECT}" -out $CERT_CSR
  
  # Create self-signed cert $CERT_SIGNED:
  local SIGNING_KEY="-signkey $CERT_KEY"
  
  openssl x509 -req -extfile <(printf "subjectAltName=DNS:$DEVICE") -in $CERT_CSR $SIGNING_KEY -out $CERT_SIGNED -days $DAYS -sha256

  chmod 644 $CERT_KEY
  cd -  
}

echo
# Create shibboleth self-signed certs
create_self_signed_cert shibboleth sp-key.pem sp-csr.pem sp-cert.pem

# Create ngins self-signed certs ( browser will report "untrusted" error )
create_self_signed_cert nginx/conf.d nginx-ssl.key nginx-ssl.csr nginx-ssl.crt

function sed_file {
  local SRCFILE="$1"
  local DSTFILE="$2"

  cp -v "$SRCFILE" "$DSTFILE"
  sed -i -e "s|{PUBLICIP}|$HOSTIP|g" "$DSTFILE"
}

echo
echo "CONFIGURING shibboleth"
sed_file template/shibboleth2.xml shibboleth/shibboleth2.xml

echo "CONFIGURING nginx"
sed_file template/port443.conf nginx/conf.d/port443.conf

echo "CONFIGURING docker-compose"
sed_file template/docker-compose.yml docker-compose.yml

echo "CREATING docker containers in background"
docker-compose up -d

echo
echo "WAITING for docker containers to be up"
sleep 5

RESULT=`nc -z -w1 ${HOSTIP} 443 && echo 1 || echo 0`

while [ $RESULT -ne 1 ]; do
  echo " **** Nginx ${HOSTIP}:443 is not responding, waiting... **** "
  sleep 5
  RESULT=`nc -z -w1 ${HOSTIP} 443 && echo 1 || echo 0`
done

if [ ! -f "$METADATA_FILE" ]; then
  echo "RETRIEVING $METADATA_URL"
  sleep 2
  curl -k $METADATA_URL > $METADATA_FILE
fi

fi

echo
echo "RERUN: to redo this setup, delete $METADATA_FILE and re-run ./setup-shib.sh $GIVENIP"
echo
echo "REGISTER this shibboleth instance by uploading file $SETUP_DIR/$METADATA_FILE to https://www.testshib.org/register.html#"
echo
echo "FINALLY browse to https://$HOSTIP .You will need to accept any error indicating the https ssl cert is invalid or not private since a self-signed cert is being used instead of an ssl certificate registered with a certificate authority"
