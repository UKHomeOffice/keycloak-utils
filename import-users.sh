#!/bin/bash

#### Globals
base_url=""
access_token=""
refresh_token=""
userid=""
realm=""
client_id=""

#### Helpers
process_result() {
  expected_status="$1"
  result="$2"
  msg="$3"

  err_msg=${result% *}
  actual_status=${result##* }

  printf "[HTTP $actual_status] $msg "
  if [ "$actual_status" == "$expected_status" ]; then
    echo "successful"
    return 0
  else
    echo "failed"
    echo -e "\t$err_msg"
    return 1
  fi
}

kc_login() {
  read -p "Base URL (e.g: https://myhostname/auth): " base_url
  read -p "Realm: " realm
  read -p "Client ID (create this client in the above Keycloak realm): " client_id
  read -p "Admin username: " admin_id
  read -s -p "Admin Password: " admin_pwd; echo

  result=$(curl --write-out " %{http_code}" -s -k --request POST \
    --header "Content-Type: application/x-www-form-urlencoded" \
    --data "username=$admin_id&password=$admin_pwd&client_id=$client_id&grant_type=password" \
    "$base_url/realms/$realm/protocol/openid-connect/token")

  admin_pwd=""  #clear password
  msg="Login"
  process_result "200" "$result" "$msg"
  if [ $? -ne 0 ]; then
    echo "Please correct error before retrying. Exiting."
    exit 1  #no point continuing if login fails
  fi

  # Extract access_token
  access_token=$(sed -E -n 's/.*"access_token":"([^"]+)".*/\1/p' <<< "$result")
  refresh_token=$(sed -E -n 's/.*"refresh_token":"([^"]+)".*/\1/p' <<< "$result")
}

kc_create_user() {
  firstname="$1"
  lastname="$2"
  username="$3"
  email="$4"

  result=$(curl -i -s -k --request POST \
  --header "Content-Type: application/json" \
  --header "Authorization: Bearer $access_token" \
  --data '{
    "enabled": "true",
    "username": "'"$username"'",
    "email": "'"$email"'",
    "firstName": "'"$firstname"'",
    "lastName": "'"$lastname"'"
  }' "$base_url/admin/realms/$realm/users")

  # userid=$(echo "$result" | grep -o "Location: .*" | egrep -o '[a-zA-Z0-9]+(-[a-zA-Z0-9]+)+') #parse userid
  # userid=`echo $userid | awk '{ print $2 }'`
  http_code=$(sed -E -n 's,HTTP[^ ]+ ([0-9]{3}) .*,\1,p' <<< "$result") #parse HTTP coded
  kc_lookup_username $username
  msg="$username: insert ($userid)"
  process_result "201" "$http_code" "$msg"
  return $? #return status from process_result
}

kc_delete_user() {
  userid="$1"

  result=$(curl --write-out " %{http_code}" -s -k --request DELETE \
  --header "Authorization: Bearer $access_token" \
  "$base_url/admin/realms/$realm/users/$userid")

  msg="$username: delete"
  process_result "204" "$result" "$msg"
  return $? #return status from process_result
}

# Convert name to uuid  setting  global userid ( This should really return etc. )
kc_lookup_username() {
  username="$1"

  result=$(curl --write-out " %{http_code}" -s -k --request GET \
  --header "Authorization: Bearer $access_token" \
  "$base_url/admin/realms/$realm/users?username=${username}")

  userid=`echo $result | grep -Eo '"id":.*?[^\\]"' | cut -d':'  -f 2 | sed -e 's/"//g'`
  
  msg="$username: lookup "
  process_result "200" "$result" "$msg"
  return $? #return status from process_result
  
}

kc_set_group_hard() {
  userid="$1"
  groupid="$2"

  result=$(curl --write-out " %{http_code}" -s -k --request PUT \
  --header "Content-Type: application/json" \
  --header "Authorization: Bearer $access_token" \
   "$base_url/admin/realms/$realm/users/$userid/groups/$groupid")
  msg="$username: group $groupid set"
  process_result "204" "$result" "$msg"
  return $? #return status from process_result
}

kc_set_pwd() {
  userid="$1"
  password="$2"

  result=$(curl --write-out " %{http_code}" -s -k --request PUT \
  --header "Content-Type: application/json" \
  --header "Authorization: Bearer $access_token" \
  --data '{
    "type": "password",
    "value": "'"$password"'",
    "temporary": "true"
  }' "$base_url/admin/realms/$realm/users/$userid/reset-password")
  msg="$username: password set to $password"
  process_result "204" "$result" "$msg"
  return $? #return status from process_result
}

kc_logout() {
  result=$(curl --write-out " %{http_code}" -s -k --request POST \
  --header "Content-Type: application/x-www-form-urlencoded" \
  --data "client_id=$client_id&refresh_token=$refresh_token" \
  "$base_url/realms/$realm/protocol/openid-connect/logout")

  msg="Logout"
  process_result "204" "$result" "$msg" #print HTTP status message
  return $? #return status from process_result
}

## Unit tests for helper functions
# Use this to check that the helper functions work
unit_test() {
  echo "Testing normal behaviour. These operations should succeed"
  kc_login
  kc_create_user john joe johnjoe john@example.com
  kc_set_pwd $userid ":Frepsip4"
  kc_set_group_hard $userid 600be026-886a-428e-8318-31fde5dac452
  kc_delete_user $userid 
  kc_logout

  #echo "Testing abnormal behaviour. These operations should fail"
  #kc_create_user john tan johntan john@tan.com #try to create acct after logout
  #kc_set_pwd "johntan" "testT3st"
  #kc_delete_user "johntan" #try to delete acct after logout
}

## Bulk import accounts
# Reads and creates accounts using a CSV file as the source
# CSV file format: "first name, last name, username, email, password"
import_accts() {
  kc_login

  # Import accounts line-by-line
  while read -r line; do
    IFS=',' read -ra arr <<< "$line"

    kc_create_user "${arr[0]}" "${arr[1]}" "${arr[2]}" "${arr[3]}"

    [ $? -ne 0 ] || kc_set_pwd "$userid" "${arr[4]}"  #skip if kc_create_user failed
    [ $? -ne 0 ] || kc_set_group_hard "$userid" "${arr[5]}" #skip if kc_create_user failed
  done < "$csv_file"

  #kc_logout
}

delete_accts(){

        kc_login
  while read -r line; do
    IFS=',' read -ra arr <<< "$line"
          kc_lookup_username "${arr[2]}"
          kc_delete_user $userid
  done < "$csv_file"
 
}

#### Main
if [ $# -lt 1 ]; then
  echo "Keycloak account admin script"
  echo "Usage: $0 [--test | --delete | --import csv_file]"
  exit 1
fi

flag=$1

case $flag in
  "--test" )
    unit_test
    ;;
        "--delete" )
    csv_file="$2"
    if [ -z "$csv_file" ]; then
      echo "Error: missing 'csv_file' argument"
      exit 1
    fi
    delete_accts $csv_file
    ;;
        "--lookup" )
          kc_login
                ;;
  "--import")
    csv_file="$2"
    if [ -z "$csv_file" ]; then
      echo "Error: missing 'csv_file' argument"
      exit 1
    fi
    import_accts $csv_file
    ;;
  *)
    echo "Unrecognised flag '$flag'"
    exit 1
    ;;
esac

exit 0