#!/usr/bin/env bash

NAMESPACE="$1"
VEX_DIR="$2"
REPORT_DIR="$3"
SEVERITY="HIGH,CRITICAL"

PODSELECTOR="component!=zeta-test-infra,component!=exauthsim,component!=testdriver,component!=testfachdienst,component!=popp-mock,app.kubernetes.io/name!=tiger-proxy,app!=authserver,app!=pep-proxy"


STATUS=0
IGNOREFILES_GLOB='/**/*snakeoil*'

for IMAGE_OBJ in $(kubectl get pod -n "$NAMESPACE" \
      -l "$PODSELECTOR" \
      -o json \
     | jq '[.items[] | {name: .metadata.name, image: .spec.containers[].image}]' \
     | jq -c 'group_by(.image)[] | {names:  [.[].name], image: .[0].image }')
do
  PODNAMES=$(echo "$IMAGE_OBJ" | jq -cr '.names')
  IMAGE_NAME=$(echo "$IMAGE_OBJ" | jq -cr '.image')
  IMAGE_FILEREF=$(echo "$IMAGE_NAME" | sed -e 's/@sha256:[a-fA-F0-9]\{64\}//; s/\(.*\):[^/:]*$/\1/' | sed -e 's/[\/:]/_/g')
  VEXFILE_NAME=$(printf '%s/%s.openvex.json' "$VEX_DIR" "$IMAGE_FILEREF")
  REPORTFILE_NAME=$(printf '%s/report.%s.json' "$REPORT_DIR" "$IMAGE_FILEREF")
  REPORTFILE_NAME_TXT=$(printf '%s/report.%s.txt' "$REPORT_DIR" "$IMAGE_FILEREF")
  echo "########################## Now scanning image $VEXFILE_NAME $IMAGE_NAME of pods $PODNAMES"

  trivy image --exit-code 0 --format json -o "$REPORTFILE_NAME" --skip-files "$IGNOREFILES_GLOB" --vex "$VEXFILE_NAME" --severity="UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL" --vuln-severity-source redhat,auto "$IMAGE_NAME"
  trivy image --exit-code 1 -o "$REPORTFILE_NAME_TXT" --skip-files "$IGNOREFILES_GLOB" --vex "$VEXFILE_NAME" --severity="$SEVERITY" --vuln-severity-source redhat,auto "$IMAGE_NAME"

  TRIVY_EXIT_CODE=$?
  if [ "$TRIVY_EXIT_CODE" -ne 0 ];
  then
    STATUS=1
  fi

  cat "$REPORTFILE_NAME_TXT"
done

exit $STATUS
