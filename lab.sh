#!/usr/bin/env bash

setup_env_vars () {
	export OS_AUTH_URL=https://ops.elastx.cloud:5000
	export OS_PROJECT_ID=39b94dd96b2c4637a51b62b6986ba179
	export OS_PROJECT_NAME="iths-patrikgafvert"
	export OS_USER_DOMAIN_NAME="Default"
	if [ -z "$OS_USER_DOMAIN_NAME" ]; then unset OS_USER_DOMAIN_NAME; fi
	export OS_PROJECT_DOMAIN_ID="default"
	if [ -z "$OS_PROJECT_DOMAIN_ID" ]; then unset OS_PROJECT_DOMAIN_ID; fi
	unset OS_TENANT_ID
	unset OS_TENANT_NAME
	export OS_USERNAME="patrik.gafvert@iths.se"
	echo "Please enter your OpenStack Password for project $OS_PROJECT_NAME as user $OS_USERNAME: "
	read -sr OS_PASSWORD_INPUT
	export OS_PASSWORD=$OS_PASSWORD_INPUT
	export OS_REGION_NAME="se-sto"
	if [ -z "$OS_REGION_NAME" ]; then unset OS_REGION_NAME; fi
	export OS_INTERFACE=public
	export OS_IDENTITY_API_VERSION=3

	export TF_VAR_user_name=$OS_USERNAME
	export TF_VAR_tenant_name=$OS_PROJECT_NAME
	export TF_VAR_password=$OS_PASSWORD
}

create_main_file () {
	
	basename="PatrikVM"
	
	web_server_count="2"
	
	echo "Creating keys for ${web_server_count} web servers and for one bastion"
	vms=("Bastion")
	
	for ((i=1;i<=${web_server_count};i++))
	do
	     vms+=("Web_Server_$i")
	done
	
	for vm in "${vms[@]}"
	do
		echo "Creating key for ${vm} stored as ${vm} and ${vm}_id_rsa.pub"
		echo -e "y\n" | ssh-keygen -q -t "rsa" -N "" -C "${vm}" -f "${vm}_id_rsa" > /dev/null 2>&1
	done
	
	echo "Creating main.tf file for deployment"
	echo "Set some env variables"
	echo "variable \"password\" {}" > main.tf
	echo "variable \"user_name\" {}" >> main.tf
	echo "variable \"tenant_name\" {}" >> main.tf
	echo "" >> main.tf

	echo "data \"local_file\" \"script\" {" >> main.tf
	echo "  filename = \"\${path.module}/web_server_script.ci\"" >> main.tf
	echo "}" >> main.tf

	echo "locals {" >> main.tf
	echo "  web_server_count_name = [" >> main.tf
	echo "    for i in range(1, ${web_server_count}+1) : format(\"web_server_%d\", i)" >> main.tf
	echo "  ]" >> main.tf
	echo "  fips_count_name = [" >> main.tf
	echo "    for i in range(1, 2+1) : format(\"fips_%d\", i)" >> main.tf
	echo "  ]" >> main.tf
	echo "}" >> main.tf

	echo "Creating provider terraform openstack"
	echo 'terraform {' >> main.tf
	echo '  required_providers {' >> main.tf
	echo '    openstack = {' >> main.tf
	echo '    source = "terraform-provider-openstack/openstack"' >> main.tf
	echo '    }' >> main.tf
	echo '  }' >> main.tf
	echo '}' >> main.tf
	echo "" >> main.tf

	echo "Get some env variables"
	echo "provider \"openstack\" {" >> main.tf
	echo "  user_name = var.user_name" >> main.tf
	echo "  tenant_name = var.tenant_name" >> main.tf
	echo "  password = var.password" >> main.tf
	echo "  auth_url = \"https://ops.elastx.cloud:5000/v3\"" >> main.tf
	echo "}" >> main.tf
	echo "" >> main.tf
	
	echo "Creating network"
	echo "resource \"openstack_networking_network_v2\" \"network\" {" >> main.tf
	echo "  name = \"${basename}_network\"" >> main.tf
	echo "  admin_state_up = true" >> main.tf
	echo "}" >> main.tf
	echo "" >> main.tf
	
	echo "Creating network subnet"
	echo "resource \"openstack_networking_subnet_v2\" \"subnet\" {" >> main.tf
	echo "  name = \"${basename}_subnet\"" >> main.tf
	echo "  network_id = openstack_networking_network_v2.network.id" >> main.tf
	echo "  cidr = \"10.0.1.0/24\"" >> main.tf
	echo "  ip_version = 4" >> main.tf
	echo "  enable_dhcp = true" >> main.tf
	echo "  dns_nameservers = [\"8.8.8.8\",\"8.8.4.4\"]" >> main.tf
	echo "}" >> main.tf
	echo "" >> main.tf
	
	echo "Creating the router"
	echo "resource \"openstack_networking_router_v2\" \"router\" {" >> main.tf
	echo "  name = \"${basename}_router\"" >> main.tf
	echo "  admin_state_up = true" >> main.tf
	echo "  external_network_id = \"600b8501-78cb-4155-9c9f-23dfcba88828\"" >> main.tf
	echo "}" >> main.tf
	echo "" >> main.tf
	
	echo "Inserting the network interface into the router"
	echo "resource \"openstack_networking_router_interface_v2\" \"ext_interface\" {" >> main.tf
	echo "  router_id = openstack_networking_router_v2.router.id" >> main.tf
	echo "  subnet_id = openstack_networking_subnet_v2.subnet.id" >> main.tf
	echo "}" >> main.tf
	echo "" >> main.tf
	
	echo "Creating floating ip's"
	echo "resource \"openstack_networking_floatingip_v2\" \"fip\" {" >> main.tf
	echo "  count = 2" >> main.tf
	echo "  pool = \"elx-public1\"" >> main.tf
	echo "}" >> main.tf
	echo "" >> main.tf
	
#	echo "resource \"openstack_compute_floatingip_associate_v2\" \"fip_assoc\" {" >> main.tf
#	echo "  floating_ip = \"\${openstack_networking_floatingip_v2.fip.*.address}\"" >> main.tf
#	echo "  instance_id = openstack_compute_instance_v2.bastion.id" >> main.tf
#	echo "}" >> main.tf
	
	echo -n "Getting the public ip, to secure the bastion what ip it could be connected from: ["
	public_ip=$(public_ip=$(dig @ns1.google.com TXT o-o.myaddr.l.google.com +short);echo "${public_ip:1:-1}")
	echo "${public_ip}]"
	
	echo "Creating the security group for the bastion and webservers"
	echo "resource \"openstack_compute_secgroup_v2\" \"ssh_sg\" {" >> main.tf
	echo "  name = \"${basename}_bastion_sg\"" >> main.tf
	echo "  description = \"Bastion ssh port security group\"" >> main.tf
	echo "  rule {" >> main.tf
	echo "    from_port = 22" >> main.tf
	echo "    to_port = 22" >> main.tf
	echo "    ip_protocol = \"tcp\"" >> main.tf
	echo "    cidr = \"${public_ip}/32\"" >> main.tf
	echo "  }" >> main.tf
	echo "}" >> main.tf
	echo "" >> main.tf
	
	echo "Creating the security group for the webservers"
	echo "resource \"openstack_compute_secgroup_v2\" \"web_sg\" {" >> main.tf
	echo "  name = \"${basename}_web_servers_sg\"" >> main.tf
	echo "  description = \"Web http port security group\"" >> main.tf
	echo "  rule {" >> main.tf
	echo "    from_port = 80" >> main.tf
	echo "    to_port = 80" >> main.tf
	echo "    ip_protocol = \"tcp\"" >> main.tf
	echo "    cidr = \"0.0.0.0/0\"" >> main.tf
	echo "  }" >> main.tf
	echo "}" >> main.tf
	echo "" >> main.tf
	
	echo "Creating config for ssh keys to the Compute"
	for vm in "${vms[@]}"
	do
		echo "resource \"openstack_compute_keypair_v2\" \"${vm,,}_keypair\" {" >> main.tf
		echo "  name = \"${basename}_${vm}_keypair\"" >> main.tf
		echo "  public_key = file(\"${vm}_id_rsa.pub\")" >> main.tf
		echo "}" >> main.tf
		echo "" >> main.tf
	done
	
	echo "Creating the server group"
	echo "resource \"openstack_compute_servergroup_v2\" \"web_srvgrp\" {" >> main.tf
	echo "  name = \"${basename}_web_servers_group\"" >> main.tf
	echo "  policies = [\"soft-anti-affinity\"]" >> main.tf
	echo "}" >> main.tf
	echo "" >> main.tf
	
	echo "Creating ${vms[@]} servers"

	echo "resource \"openstack_compute_instance_v2\" \"web_cluster\" {" >> main.tf
	echo "  for_each = toset(local.web_server_count_name)" >> main.tf
	echo "  name = each.value" >> main.tf
	echo "  availability_zone = \"sto3\"" >> main.tf
	echo "  image_name = \"ubuntu-22.04-server-latest\"" >> main.tf
	echo "  flavor_name = \"v1-micro-1\"" >> main.tf
	echo "  network {" >> main.tf
	echo "    uuid = openstack_networking_network_v2.network.id" >> main.tf
	echo "  }" >> main.tf
	echo "  key_pair = \"openstack_compute_keypair_v2.\${each.value}_keypair.name\"" >> main.tf
	echo "  scheduler_hints {" >> main.tf
	echo "    group = openstack_compute_servergroup_v2.web_srvgrp.id" >> main.tf
	echo "  }" >> main.tf
	echo "  security_groups = [openstack_compute_secgroup_v2.web_sg.name, openstack_compute_secgroup_v2.ssh_sg.name]" >> main.tf
	echo "  user_data = data.local_file.script.content" >> main.tf
	echo "  depends_on = [openstack_networking_subnet_v2.subnet]" >> main.tf
	echo "}" >> main.tf
	echo "" >> main.tf

	echo "resource \"openstack_compute_instance_v2\" \"bastion\" {" >> main.tf
	echo "  name = \"${basename}_${vms[0]}\"" >> main.tf
	echo "  availability_zone = \"sto3\"" >> main.tf
	echo "  image_name = \"debian-11-latest\"" >> main.tf
	echo "  flavor_name = \"v1-micro-1\"" >> main.tf
	echo "  network {" >> main.tf
	echo "    uuid = openstack_networking_network_v2.network.id" >> main.tf
	echo "  }" >> main.tf
	echo "  key_pair = openstack_compute_keypair_v2.${vms[0],,}_keypair.name" >> main.tf
	echo "  security_groups = [openstack_compute_secgroup_v2.ssh_sg.name]" >> main.tf
	echo "  depends_on = [openstack_networking_subnet_v2.subnet]" >> main.tf
	echo "}" >> main.tf
	echo "" >> main.tf
}

case $1 in
	init)
		setup_env_vars
		create_main_file
		terraform apply
	;;
	start)
		setup_env_vars
		create_main_file
	;;
	destroy)
		setup_env_vars
		terraform destroy
	;;
	envvars)
		setup_env_vars
	;;
	*)
		echo "Usage: "
		echo ". $0 envvars (jyst set the enviroment variables for openstack & terraform in current shell)"
		echo "$0 start (just create main.tf file)"
		echo "$0 init (create main.tf file and terraform init)"
		echo "$0 destroy (destroy the terraform main.tf)"
	;;
esac
