variable "node_count" {
  description = "Antal Ubuntu-noder att skapa (3 för ett MongoDB replica set)"
  type        = number
  default     = 3
}

variable "memory_mb" {
  description = "RAM per nod i MB"
  type        = number
  default     = 2048
}

variable "vcpu" {
  description = "Antal vCPU per nod"
  type        = number
  default     = 2
}

variable "disk_size_gb" {
  description = "Diskstorlek per nod i GB"
  type        = number
  default     = 20
}

variable "base_image_path" {
  description = "Sökväg eller URL till Ubuntu cloud image (t.ex. noble-server-cloudimg-amd64.img)"
  type        = string
  default     = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "libvirt_network_name" {
  description = "Namn på det libvirt-nätverk noderna ska anslutas till (t.ex. 'default')"
  type        = string
  default     = "default"
}

variable "network_cidr" {
  description = "CIDR för nätverket noderna får statiska IP:er i (måste matcha libvirt-nätverkets subnät)"
  type        = string
  default     = "192.168.122.0/24"
}

variable "node_ip_start" {
  description = "Sista octet-startvärde för nodernas statiska IP:er, t.ex. 101 -> .101, .102, .103"
  type        = number
  default     = 101
}

variable "ssh_public_key" {
  description = "Din publika SSH-nyckel som läggs in i alla noder (för Ansible-åtkomst)"
  type        = string
}

variable "stopped_nodes" {
  description = "Nodnummer (1-baserat, t.ex. [2]) som ska vara avstängda. Tom lista = alla körs. Diskarna behålls."
  type        = list(number)
  default     = []
}
