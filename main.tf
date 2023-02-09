variable "password" {
  type = string
}

variable "user_name" {
  type = string
}

variable "tenant_name" {
  type = string
}

variable "vmbasename" {
  type    = string
  default = "PatrikVM"
}

locals {
  web_servers_count = 2
  web_server_count_name = [
    for i in range(1, local.web_servers_count + 1) : format("web_server_%d", i)
  ]

  name = concat(local.web_server_count_name, ["bastion"])
}

terraform {
  required_providers {
    openstack = {
      source = "terraform-provider-openstack/openstack"
    }
  }
}

# data "external" "sshkeygen" {
# for_each = toset(local.name)
#   program = [
#     "bash", "-c","jq -r -n --arg pubkey \"$(ssh-keygen -y -f ${each.value}_rsa)\" '{pubkey:$pubkey}'"
#   ]
# }

data "external" "public_key" {
  for_each = toset(local.name)
  program = [
    "bash", "-c", "jq -r -n --arg pubkey \"$(ssh-keygen -y -f ${each.value}_rsa)\" '{pubkey:$pubkey}'"
  ]
  #  depends_on = [data.external.sshkeygen]
}

resource "openstack_compute_keypair_v2" "keypair" {
  for_each   = toset(local.name)
  name       = each.value
  public_key = data.external.public_key[each.value].result["pubkey"]
  depends_on = [data.external.public_key]
}

provider "openstack" {
  user_name   = var.user_name
  tenant_name = var.tenant_name
  password    = var.password
  auth_url    = "https://ops.elastx.cloud:5000/v3"
}

resource "openstack_networking_network_v2" "network" {
  name           = "${var.vmbasename}_network"
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "subnet" {
  name            = "${var.vmbasename}_subnet"
  network_id      = openstack_networking_network_v2.network.id
  cidr            = "10.0.1.0/24"
  ip_version      = 4
  enable_dhcp     = true
  dns_nameservers = ["8.8.8.8", "8.8.4.4"]
}

resource "openstack_networking_router_v2" "router" {
  name                = "${var.vmbasename}_router"
  description         = "Router"
  admin_state_up      = true
  external_network_id = "600b8501-78cb-4155-9c9f-23dfcba88828"
}

resource "openstack_networking_router_interface_v2" "router_interface" {
  router_id = openstack_networking_router_v2.router.id
  subnet_id = openstack_networking_subnet_v2.subnet.id
}

resource "openstack_compute_secgroup_v2" "internet_ssh_sg" {
  name        = "${var.vmbasename}_Internet_ssh_sg"
  description = "ssh port security group"
  rule {
    from_port   = 22
    to_port     = 22
    ip_protocol = "tcp"
    cidr        = "0.0.0.0/0"
  }
}

resource "openstack_compute_secgroup_v2" "internet_http_sg" {
  name        = "${var.vmbasename}_Internet_http_sg"
  description = "http port security group"
  rule {
    from_port   = 80
    to_port     = 80
    ip_protocol = "tcp"
    cidr        = "0.0.0.0/0"
  }
}

resource "openstack_compute_secgroup_v2" "local_ssh_sg" {
  name        = "${var.vmbasename}_Local_ssh_sg"
  description = "http port security group"
  rule {
    from_port   = 22
    to_port     = 22
    ip_protocol = "tcp"
    cidr        = "10.0.1.0/24"
  }
}

resource "openstack_compute_secgroup_v2" "local_http_sg" {
  name        = "${var.vmbasename}_Local_http_sg"
  description = "http port security group"
  rule {
    from_port   = 80
    to_port     = 80
    ip_protocol = "tcp"
    cidr        = "10.0.1.0/24"
  }
}

resource "openstack_compute_instance_v2" "bastion" {
  name              = "${var.vmbasename}_Bastion"
  availability_zone = "sto3"
  image_name        = "debian-11-latest"
  flavor_name       = "v1-micro-1"
  network {
    uuid = openstack_networking_network_v2.network.id
  }
  key_pair        = openstack_compute_keypair_v2.keypair["bastion"].name
  security_groups = [openstack_compute_secgroup_v2.internet_ssh_sg.name]
  depends_on      = [openstack_networking_subnet_v2.subnet]
  # user_data       = ""
}

resource "openstack_compute_instance_v2" "web_cluster" {
  for_each          = toset(local.web_server_count_name)
  name              = "${var.vmbasename}_${each.value}"
  availability_zone = "sto3"
  image_name        = "ubuntu-22.04-server-latest"
  flavor_name       = "v1-micro-1"
  network {
    uuid = openstack_networking_network_v2.network.id
  }
  key_pair = openstack_compute_keypair_v2.keypair[each.value].name
  scheduler_hints {
    group = openstack_compute_servergroup_v2.web_srvgrp.id
  }
  security_groups = [openstack_compute_secgroup_v2.local_ssh_sg.name, openstack_compute_secgroup_v2.local_http_sg.name]
  user_data       = file("web_server_script.ci")
  depends_on      = [openstack_networking_subnet_v2.subnet]
}

resource "openstack_compute_servergroup_v2" "web_srvgrp" {
  name     = "${var.vmbasename}_web_servers_group"
  policies = ["soft-anti-affinity"]
}

resource "openstack_lb_loadbalancer_v2" "loadbalancer" {
  name               = "${var.vmbasename}_loadbalancer"
  vip_subnet_id      = openstack_networking_subnet_v2.subnet.id
  security_group_ids = [openstack_compute_secgroup_v2.internet_http_sg.id]
}

resource "openstack_lb_listener_v2" "loadbalancerlistener" {
  name            = "${var.vmbasename}_loadbalancer_listener"
  protocol        = "HTTP"
  protocol_port   = 80
  loadbalancer_id = openstack_lb_loadbalancer_v2.loadbalancer.id
  insert_headers = {
    X-Forwarded-For = "true"
  }
}

resource "openstack_lb_pool_v2" "loadbalancer_pool" {
  name        = "${var.vmbasename}_loadbalancer_pool"
  protocol    = "HTTP"
  lb_method   = "ROUND_ROBIN"
  listener_id = openstack_lb_listener_v2.loadbalancerlistener.id
}

resource "openstack_lb_member_v2" "loadbalancer_pool_member" {
  for_each      = toset(local.web_server_count_name)
  name          = "${var.vmbasename}_loadbalancer_pool_member_${each.value}"
  pool_id       = openstack_lb_pool_v2.loadbalancer_pool.id
  address       = openstack_compute_instance_v2.web_cluster[each.value].access_ip_v4
  protocol_port = 80
}

resource "openstack_lb_monitor_v2" "loadbalancer_pool_member_monitor" {
  name        = "${var.vmbasename}_loadbalancer_pool_member_monitor"
  pool_id     = openstack_lb_pool_v2.loadbalancer_pool.id
  type        = "HTTP"
  url_path    = "/health.html"
  http_method = "GET"
  max_retries = 3
  delay       = 5
  timeout     = 5
}

resource "openstack_compute_floatingip_v2" "cfloatips" {
  pool = "elx-public1"
}

resource "openstack_networking_floatingip_v2" "nfloatips" {
  pool = "elx-public1"
}

resource "openstack_compute_floatingip_associate_v2" "fip" {
  instance_id = openstack_compute_instance_v2.bastion.id
  floating_ip = openstack_compute_floatingip_v2.cfloatips.address
}

resource "openstack_networking_floatingip_associate_v2" "fip" {
  port_id     = openstack_lb_loadbalancer_v2.loadbalancer.vip_port_id
  floating_ip = openstack_networking_floatingip_v2.nfloatips.address
}
