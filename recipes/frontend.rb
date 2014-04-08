#
# Cookbook Name:: rs-haproxy
# Recipe:: frontend
#
# Copyright (C) 2014 RightScale, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

marker "recipe_start_rightscale" do
  template "rightscale_audit_entry.erb"
end

include_recipe 'rightscale_tag::default'

class Chef::Recipe
  include Rightscale::RightscaleTag
end

# Find all application servers in the deployment
app_servers = find_application_servers(node)
app_server_pools = group_servers_by_application_name(app_servers)

# If this recipe is called via the remote_recipe resource, merge the
# application server information sent through the resource with the
# application server pools hash. This is to ensure the application server
# which made the remote recipe call is added to the list of application servers
# in the deployment.
unless node['remote_recipe'].nil? || node['remote_recipe'].empty?
  raise "Load balancer pool name is missing in the remote recipe call!" if node['remote_recipe']['pool_name'].nil?
  remote_server_pool = node['remote_recipe']['pool_name']

  raise "Instance UUID of the remote server is missing!" if node['remote_recipe']['application_server_id'].nil?
  remote_server_uuid = node['remote_recipe']['application_server_id']

  case node['remote_recipe']['application_action']
  when 'attach'
    # Add the application server information to the respective pool
    app_server_pools[remote_server_pool] ||= {}
    app_server_pools[remote_server_pool][remote_server_uuid] = {
      'bind_ip_address' => node['remote_recipe']['application_bind_ip'],
      'bind_port' => node['remote_recipe']['application_bind_port'],
      'vhost_path' => node['remote_recipe']['vhost_path']
    }
  when 'detach'
    # Remove application server from the respective pool
    if app_server_pools[remote_server_pool]
      app_server_pools[remote_server_pool].delete(remote_server_uuid)
    end
  end

  # Reset the 'remote_recipe' hash in the node to nil to ensure subsequent recipe runs
  # don't use the existing values from this hash.
  node.set['remote_recipe'] = nil
end

# Initialize frontend section which will be generated in the haproxy.cfg
node.set['haproxy']['config']['frontend'] = {}
node.set['haproxy']['config']['frontend']['all_requests'] ||= {}
node.set['haproxy']['config']['frontend']['all_requests']['default_backend'] = node['rs-haproxy']['pools'].last

# Initialize backend section which will be generated in the haproxy.cfg
node.set['haproxy']['config']['backend'] = {}

# Iterate through each application server pool served by the HAProxy server and set up the
# ACLs in the frontend section and the corresponding backed sections
node['rs-haproxy']['pools'].each do |pool_name|
  backend_servers_list = []

  if node['rs-haproxy']['session_stickiness']
    # When cookie is enabled the haproxy.cnf should have this dummy server
    # entry for the haproxy to start without any errors
    backend_servers_list << {'disabled-server 127.0.0.1:1' => {'disabled' => true}}
  end

  # If there exists application servers with application name same as pool name add those
  # servers to the corresponding backend section in the haproxy.cfg. Also, set up the ACLs
  # based on the vhost_path information in the application server.
  unless app_server_pools[pool_name].nil?
    acl_setting = ''
    app_server_pools[pool_name].each do |server_uuid, server_hash|
      if server_hash['vhost_path'].include?('/')
        # If vhost_path contains a '/' then the ACL should match the path in the request URI.
        # e.g., if the request URI is www.example.com/index then the ACL will match '/index'
        acl_setting = "path_dom -i #{server_hash['vhost_path']}"
      else
        # Else the ACL should match the domain name of the request URI.
        # e.g., if the request URI is http://test.example.com then the ACL will
        # match 'test.example.com' and if the request URI is http://example.com
        # then the ACL will match 'example.com'
        acl_setting = "hdr_dom(host) -i -m dom #{server_hash['vhost_path']}"
      end

      backend_server = "#{server_uuid} #{server_hash['bind_ip_address']}:#{server_hash['bind_port']}"
      backend_server_hash = {
        'inter' => 300,
        'rise' => 2,
        'fall' => 3,
        'maxconn' => node['haproxy']['member_max_connections']
      }

      if node['haproxy']['http_chk']
        backend_server_hash['check'] = true
      end

      # Configure cookie for backend server
      if node['rs-haproxy']['session_stickiness']
        backend_server_hash['cookie'] = backend_server.split(' ').first
      end

      backend_servers_list << {backend_server => backend_server_hash}
    end

    # Set up ACLs based on the vhost_path information from the application servers
    acl_name = "acl_#{pool_name}"
    node.set['haproxy']['config']['frontend']['all_requests']['acl'] ||= {}
    node.set['haproxy']['config']['frontend']['all_requests']['acl'][acl_name] = acl_setting
    node.set['haproxy']['config']['frontend']['all_requests']['use_backend'] ||= {}
    node.set['haproxy']['config']['frontend']['all_requests']['use_backend'][pool_name] = "if #{acl_name}"
  end

  # Set up backend section for each application server pool served by HAProxy
  node.set['haproxy']['config']['backend'][pool_name] = {}
  node.set['haproxy']['config']['backend'][pool_name]['server'] ||= []
  node.set['haproxy']['config']['backend'][pool_name]['server'] = backend_servers_list
end

include_recipe 'rs-haproxy::default'
