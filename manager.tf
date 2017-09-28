###############################################################################
### IBM Cloud Provider
###############################################################################

provider "ibm" {
    softlayer_username = "${var.softlayer_username}"
    softlayer_api_key  = "${var.softlayer_api_key}"
}

data "ibm_compute_ssh_key" "ssh_key" {
    label = "${var.ssh_key_label}"
}

resource "ibm_compute_ssh_key" "environment_ssh_key" {
    label = "${var.name}-key"
    notes = "Needed by the ${var.name} swarm."
    public_key = "${var.ssh_public_key}"
}

resource "ibm_compute_vm_instance" "manager" {
    dedicated_acct_host_only = "${lookup(var.hw_type_map, var.hw_type)}"
    hostname                 = "${var.name}-mgr1"
    domain                   = "ibmcloud.com"
    os_reference_code       = "UBUNTU_LATEST"
    post_install_script_uri = "https://d4b-userdata.mybluemix.net/execute-userdata.sh"
    datacenter               = "${var.datacenter}"
    cores                    = "${lookup(var.machine_type_mgr_cores_map, var.manager_machine_type)}"
    memory                   = "${lookup(var.machine_type_mgr_memory_map, var.manager_machine_type)}"
    local_disk               = true
    hourly_billing           = true
    ssh_key_ids              = ["${data.ibm_compute_ssh_key.ssh_key.id}","${ibm_compute_ssh_key.environment_ssh_key.id}"]
    tags                     = ["logicalid:mgr1"]
    user_metadata            = <<EOD
mkdir -p ${var.working_dir}/groups/scripts
cat << EOF > ${var.working_dir}/groups/d4ic-vars.json
{
"cluster_swarm_worker_size":${var.worker_count},
"cluster_swarm_manager_size":${var.manager_count},
"cluster_swarm_name":"${var.name}",
"cluster_swarm_sshkey_id":${data.ibm_compute_ssh_key.ssh_key.id},
"cluster_swarm_environment_sshkey_id":${ibm_compute_ssh_key.environment_ssh_key.id},
"cluster_swarm_linuxkit_imageid":${var.linuxkit_imageid},
"cluster_swarm_datacenter":"${var.datacenter}",
"cluster_swarm_dedicated_compute_hosts":${lookup(var.hw_type_map, var.hw_type)},
"cluster_swarm_synthetic":${var.synthetic},
"cluster_swarm_reg_token":"${var.reg_token}",
"infrakit_docker_image":"${var.infrakit_image}",
"infrakit_logging_level":${var.logging_level},
"cluster_swarm_manager_cores":${lookup(var.machine_type_mgr_cores_map, var.manager_machine_type)},
"cluster_swarm_manager_memory":${lookup(var.machine_type_mgr_memory_map, var.manager_machine_type)},
"cluster_swarm_worker_cores":${lookup(var.machine_type_wkr_cores_map, var.worker_machine_type)},
"cluster_swarm_worker_memory":${lookup(var.machine_type_wkr_memory_map, var.worker_machine_type)},
"schematics_url":"${var.schematics_url}",
"schematics_environment_id":"${var.schematics_environment_id}",
"schematics_environment_name":"${var.schematics_environment_name}"
}
EOF
cd ${var.working_dir}/groups
base_url=$(echo ${var.base_url} | sed 's/GIT_TOKEN/${var.git_token}/g')
while true; do
  wget -q --auth-no-challenge --retry-connrefused --waitretry=1 --read-timeout=30 --timeout=5 $base_url/scripts/pull-scripts.sh -O scripts/pull-scripts.sh
  if [ $? -eq 0 ]; then break; else sleep 2s; fi
done
bash scripts/pull-scripts.sh $base_url index-ubuntu.txt
sh ${var.working_dir}/groups/scripts/ubuntu/harden-ubuntu.sh
sh ${var.working_dir}/groups/scripts/ubuntu/apt-get-mgr.sh
sh ${var.working_dir}/groups/scripts/ubuntu/install-docker-mgr.sh
while true; do
  docker login -u token -p "${var.reg_token}" registry.ng.bluemix.net
  docker pull ${var.infrakit_image}
  if [ $? -eq 0 ]; then break; else sleep 2s; fi
done
docker run --rm -v ${var.working_dir}/groups/:/infrakit_files ${var.infrakit_image} infrakit template file:////infrakit_files/scripts/ubuntu/boot.sh --var /cluster/swarm/initialized=false --var /local/infrakit/role/worker=false --var /local/infrakit/role/manager=true --var /local/infrakit/role/manager/initial=true --var /provider/image/hasDocker=yes --final=true | tee ${var.working_dir}/groups/boot.mgr1 | SOFTLAYER_USERNAME=${var.softlayer_username} SOFTLAYER_API_KEY=${var.softlayer_api_key} sh
EOD

    # On destroy commands
    provisioner "remote-exec" {
        when = "destroy"
        on_failure = "continue"
        inline = [
          "sudo /var/ibm/d4ic/infrakit.sh group/workers destroy; sudo /var/ibm/d4ic/infrakit.sh group/managers destroy"
        ]
        connection {
          type        = "ssh"
          user        = "docker"
          private_key = "${var.ssh_private_key}"
        }
    }
}

###############################################################################
### Variables
###############################################################################

# Softlayer credentials
variable softlayer_username {}
variable softlayer_api_key {}

# Number of managers to deploy
variable manager_count {
    default = 1
}

# Number of workers to deploy
variable worker_count {
    default = 1
}

# Softlayer label for SSH key to use for the manager
variable ssh_key_label {
    default = "publickey"
}

# Softlayer private SSH key used for deployment only
variable ssh_private_key {
    default = ""
}

# Softlayer public SSH key used for deployment only
variable ssh_public_key {
    default = ""
}

# Softlayer datacenter to deploy the manager
variable datacenter {
    default = ""
}

# Swarm name; workers and managers have this prefix
variable name {
    default = "D4B"
}

# Directory where files are pushed to the manager
variable working_dir {
    default = "/var/ibm/d4ic/tmp"
}

# Logging for terraform when spinning up the worker nodes. 1 is the least verbose, 5 is the most verbose
# The exact levels are: 5=TRACE, 4=DEBUG, 3=INFO, 2=WARN or 1=ERROR
variable logging_level {
    default = 4
}

# Image used for deployment
variable infrakit_image {
    default = ""
}

variable linuxkit_imageid {
    default = 1704203
}

# Map value is associated with the ibm_compute_vm_instance.dedicated_acct_host_only attribute
variable hw_type_map {
    type = "map"
    default = {
        shared = 0
        dedicated = 1
    }
}

variable hw_type {
    default = "shared"
}

# Map value for the machine type (ie flavor) for both manager and worker nodes in the swarm
variable machine_type_mgr_cores_map {
    type = "map"
    default = {
        u1c.1x2    = 1
        u1c.2x4    = 2
        b1c.4x16   = 4
        b1c.16x64  = 16
        b1c.32x128 = 32
        b1c.56x242 = 56
    }
}

variable machine_type_mgr_memory_map {
    type = "map"
    default = {
        u1c.1x2    = 2048
        u1c.2x4    = 4096
        b1c.4x16   = 16384
        b1c.16x64  = 65536
        b1c.32x128 = 131072
        b1c.56x242 = 247808
    }
}

variable machine_type_wkr_cores_map {
    type = "map"
    default = {
        u1c.1x2    = 1
        u1c.2x4    = 2
        b1c.4x16   = 4
        b1c.16x64  = 16
        b1c.32x128 = 32
        b1c.56x242 = 56
    }
}

variable machine_type_wkr_memory_map {
    type = "map"
    default = {
        u1c.1x2    = 2048
        u1c.2x4    = 4096
        b1c.4x16   = 16384
        b1c.16x64  = 65536
        b1c.32x128 = 131072
        b1c.56x242 = 247808
    }
}

variable manager_machine_type {
    default = "u1c.1x2"
}

variable worker_machine_type {
    default = "u1c.1x2"
}

# Base URL to pull all group files from; not that terraform does not support nested vars
# so the GIT_TOKEN is sed'd out at runtime
variable base_url {
    default = "https://GIT_TOKEN:@raw.github.ibm.com/ibmcloud/docker-for-bluemix/master/deploy/groups"
}

# Used to pull from internal GHE
variable git_token {
    default = ""
}

variable schematics_environment_name {
    default = ""
}

variable schematics_environment_id {
    default = ""
}

variable schematics_url {
    default = ""
}

# Denotes that the swarm is for testing only
variable synthetic {
    default = false
}

variable reg_token {
    default = ""
}

###############################################################################
### Outputs
###############################################################################

output "swarm_name" {
    value = "${var.name}"
}

output "manager_public_ip" {
    value = "${ibm_compute_vm_instance.manager.ipv4_address}"
}

output "manager_private_ip" {
    value = "${ibm_compute_vm_instance.manager.ipv4_address_private}"
}

output "worker_count_initial" {
    value = "${var.worker_count}"
}

output "manager_count" {
    value = "${var.manager_count}"
}

output "environment_ssh_key_id" {
  value = "${ibm_compute_ssh_key.environment_ssh_key.id}"
}
