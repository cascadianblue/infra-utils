# Provisioning a stack with the same name will update the resources in the stack.
# This script helps ensure that stack names for newly provisioned stacks are
# unique so as to prevent new stacks from changing resources of exisitng stacks.
#!/bin/bash
set -e
set -o pipefail

# Name can only contain alpha, number or hyphens, 1st char must be alpha.
# TODO - need to add the following constraints:
#   cannot contain square bracket characters
#   string length must be less than 128 characters
STACK_NAME_CONSTRAINT="^[a-zA-Z][a-zA-Z0-9.-][^_~\`/{},.\"()\"+=\\<>?:;|!@#$%^&*[:space:]]*$"

# util to print a generic list
print_list() {
  local list=("$@")
  for item in "${list[@]}"
  do
    printf "${item}\n"
  done
}

# Get existing stack names from local files
get_local_stack_names() {
  # get stack names and strip spaces and tabs from string
  stack_names=( $(/bin/grep -r -w -h '^stack_name:' ${PATH} | /usr/bin/cut -d':' -f2 | /usr/bin/tr -d '\040\011\042\047') )
  printf "Local stack names:\n"
  print_list "${stack_names[@]}" # FIXME: Delete this line
}

# Get existing stack names from cloudformation
get_cf_stack_names() {
  stack_names=( $(aws cloudformation list-stacks \
      --query 'StackSummaries[?starts_with(StackStatus, `DELETE_COMPLETE`) != `true`].StackName' \
      --output text) )
  printf "CF stack names:\n"
  print_list "${stack_names[@]}" # FIXME: Delete this line
}

# Get names of newly-added stacks
get_new_stack_names() {
  new_stack_names=()
  # get stack name and strip spaces/tabs/new line/carriage return from string
  /usr/bin/git diff --unified=0 HEAD~1 | /bin/grep '^+stack_name:' | while read -r line; do
    new_stack_names+=($(/usr/bin/cut -d':' -f2 <<< ${line} | /usr/bin/tr -d '\040\011\012\015\042\047'))
  done
  printf "New stack name(s):"
  print_list "${new_stack_names[@]}"
}

# Get the OwnerEmail in newly added stack name
get_owner_email() {
  # get stack name and strip spaces/tabs/new line/carriage return from string
  local diff_output=$(/usr/bin/git diff --unified=0 HEAD~1 | /bin/grep '^\+.*OwnerEmail:' || true)
  owner_email=$(/usr/bin/cut -d':' -f2 <<< ${diff_output} | /usr/bin/tr -d '\040\011\012\015\042\047')
}

# Verify new stack_name is unique
verify_unique() {
  for stack_name in "${stack_names[@]}"
  do
    if [ "${new_stack_name}" = "${stack_name}" ]; then
      printf "\e[1;31mERROR: new stack_name \"${new_stack_name}\" is not unique\e[0m\n"
      printf "Existing stacks names:\n"
      print_list "${stack_names[@]}"
      exit 1
     fi
  done
}

# Verify that new stack_name contains valid chars and is a certain length
verify_name_constraint() {
  if [[ ! $new_stack_name =~ $STACK_NAME_CONSTRAINT ]]; then
    printf "\e[1;31mERROR: Stack name \"${new_stack_name}\" contains invalid characters. "
    printf "A stack name can contain only alphanumeric characters (case sensitive) and hyphens. "
    printf "It must start with an alphabetic character and cannot be longer than 128 characters.\e[0m\n"
    exit 1
  fi
}

# Get the list of new or changed files
get_diff_files() {
  local diff_output=$(/usr/bin/git diff --name-only HEAD~1 )
  files=($diff_output)
}

# Verify sceptre files are valid
verify_sceptre_files() {
  for file in "${files[@]}"
  do
    # sceptre files are in the config folder
    if [[ "$file" =~ "config" ]]; then
      if [[ $file != *.yaml && $file != *.j2 && $file != *.json ]]; then
        printf "\e[1;31mERROR: \"${file}\" is an invalid template file.  "
        printf "A valid file must contain either a json, yaml or j2 extension\e[0m\n"
        exit 1
      fi
    fi
  done
}

# Verify owner's email exists in jumpcloud to assign systems to users
verify_owner_email() {
  local jc_api_key=$(aws ssm get-parameters \
                     --names /infra/JcServiceApiKey \
                     --with-decryption \
                     --query "Parameters[*].{Value:Value}" \
                     --out text)
  local user_id=$(/usr/bin/curl --silent --show-error -X GET https://console.jumpcloud.com/api/systemusers \
                  -H 'Accept: application/json' \
                  -H 'Content-Type: application/json' \
                  -H 'x-api-key: '"${jc_api_key}" | jq -r '.results | .[] | select(.email=='\"${owner_email}\"') | .id')
  if [[ -z "${user_id}" ]]; then
    printf "\e[1;31mERROR: \"${owner_email}\" is an invalid OwnerEmail.  "
    printf "The owner email must match an existing email in jumpcloud\e[0m\n"
    exit 1
  fi
}


# main
cmd(){ echo `basename $0`; }
usage() {                                      # Function: Print a help message.
echo "\
usage: `cmd` [ -r ] [ -l PATH ]
-r Verify against cloudformation
-l Verify against local files in PATH
"
}

exit_abnormal() {                              # Function: Exit with error.
  usage
  exit 1
}

if [ $# -eq 0 ]; then                          # Requires at least one argument
    exit_abnormal
fi

while getopts ":rl:" options; do
  case "${options}" in
    r) get_new_stack_name
      # TODO: Change the following functions to work on lists; find a way to test them
       if [ ! -z "${new_stack_name}" ]; then
         verify_name_constraint
         get_cf_stack_names
         verify_unique
       fi
       get_owner_email
       if [ ! -z "${owner_email}" ]; then
         verify_owner_email
       fi
      ;;
    l) PATH=${OPTARG}
       # verify sceptre files
       get_diff_files
       verify_sceptre_files
       # verify stack names
       get_new_stack_names
       if [ ! ${#new_stack_names[@]} -eq 0 ]; then
         # TODO: Make the following functions work on lists
         verify_name_constraint
         # get all stack names from the last commit
         ( /usr/bin/git checkout HEAD~1 ) 2> /dev/null
         get_local_stack_names
         ( /usr/bin/git checkout - ) 2> /dev/null
         verify_unique
       fi
      ;;
    :)                            # If expected argument omitted:
      printf "\e[1;31mError: -${OPTARG} requires an argument.\e[0m\n"
      exit_abnormal
      ;;
    *)                            # If unknown (any other) option:
      exit_abnormal
      ;;
  esac
done
