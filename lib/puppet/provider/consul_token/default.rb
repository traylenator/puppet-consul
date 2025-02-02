require 'json'
require 'net/http'
require 'pp'
require 'uri'
require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', '..', 'puppet_x', 'consul', 'acl_base.rb'))

Puppet::Type.type(:consul_token).provide(
  :default
) do
  mk_resource_methods

  def self.prefetch(resources)
    resources.each do |_name, resource|
      tokens = list_tokens(resource[:acl_api_token], resource[:hostname], resource[:port], resource[:protocol], resource[:api_tries])
      token = tokens.select { |token| token.accessor_id == resource[:accessor_id] }

      resource.provider = new({}, @client, token.any? ? token.first : nil, resource)
    end
  end

  def self.list_tokens(acl_api_token, hostname, port, protocol, tries)
    @token_collection ||= nil
    return @token_collection if @token_collection

    @client ||= ConsulACLTokenClient.new(hostname, port, protocol, acl_api_token)
    @token_collection = @client.get_token_list(tries)
    @token_collection
  end

  def initialize(messages, client = nil, existing_token = nil, resource = nil)
    super(messages)
    @property_flush = {}

    @client = client
    @existing_token = existing_token

    if resource
      @property_hash = {
        secret_id: resource[:secret_id],
      }
    end

    if existing_token
      @property_hash[:accessor_id] = existing_token.accessor_id
      @property_hash[:description] = existing_token.description

      if existing_token.is_policy_list_equal(resource[:policies_by_id], resource[:policies_by_name])
        @property_hash[:policies_by_id] = resource[:policies_by_id]
        @property_hash[:policies_by_name] = resource[:policies_by_name]
      end
    end
  end

  def exists?
    @existing_token
  end

  def create
    @property_flush[:ensure] = :present
  end

  def destroy
    @property_flush[:ensure] = :absent
  end

  def flush
    if @resource[:ensure] != :absent && !@existing_token
      created_token = @client.create_token(@resource[:accessor_id], @resource[:name], @resource[:policies_by_name], @resource[:policies_by_id], @resource[:api_tries],
                                           @resource[:secret_id] || nil)
      @resource[:accessor_id] = created_token.accessor_id
      @resource[:secret_id] = created_token.secret_id

      Puppet.info("Created token #{created_token.description} with Accessor ID  #{created_token.accessor_id}")
    elsif @resource[:ensure] != :absent && @existing_token &&
          (!@existing_token.is_policy_list_equal(@resource[:policies_by_id], @resource[:policies_by_name]) || @existing_token.description != @resource[:description])
      new_policy_list = @client.update_token(@existing_token.accessor_id, @resource[:description], @resource[:policies_by_name], @resource[:policies_by_id])
      @existing_token.policies = new_policy_list
      @existing_token.description = @resource[:description]

      Puppet.info("Updated token #{@existing_token.description} (Accessor ID: #{@existing_token.accessor_id}")
    elsif @resource[:ensure] == :absent && @existing_token
      @client.delete_token(@resource[:accessor_id])
      @resource[:accessor_id] = ''

      Puppet.info("Deleted token #{@existing_token.description} (Accessor ID: #{@existing_token.accessor_id}")
    end
  end

  def self.reset
    @client = nil
    @token_collection = nil
  end
end

class ConsulToken
  attr_accessor :description, :policies
  attr_reader :accessor_id, :secret_id

  def initialize(accessor_id, secret_id, description, policies)
    @accessor_id = accessor_id
    @secret_id = secret_id
    @description = description
    @policies = policies
  end

  def is_policy_list_equal(policies_by_id, policies_by_name)
    total_length = (policies_by_id.length + policies_by_name.length)
    return false if @policies.length != total_length

    actual_policies_by_id = @policies.map(&:policy_id)
    actual_policies_by_name = @policies.map(&:policy_name)

    (policies_by_id - actual_policies_by_id).empty? && (policies_by_name - actual_policies_by_name).empty?
  end
end

class ConsulTokenPolicyLink
  attr_reader :policy_id, :policy_name

  def initialize(policy_id, policy_name)
    @policy_id = policy_id
    @policy_name = policy_name
  end
end

class ConsulACLTokenClient < PuppetX::Consul::ACLBase::BaseClient
  def get_token_list(tries)
    begin
      response = get('/tokens', tries)
    rescue StandardError => e
      Puppet.warning("Cannot retrieve ACL token list: #{e.message}")
      response = {}
    end

    collection = []
    response.each do |item|
      collection.push(ConsulToken.new(item['AccessorID'], item['SecretID'], item['Description'], parse_policies(item['Policies'])))
    end

    collection
  end

  def create_token(accessor_id, description, policies_by_name, policies_by_id, tries, secret_id = nil)
    begin
      body = encode_body(accessor_id, description, policies_by_name, policies_by_id, secret_id)
      response = put('/token', body, tries)
    rescue StandardError => e
      Puppet.warning("Unable to create token #{description}: #{e.message}")
      return nil
    end

    ConsulToken.new(response['AccessorID'], response['SecretID'], description, parse_policies(response['Policies']))
  end

  def update_token(accessor_id, description, policies_by_name, policies_by_id)
    begin
      body = encode_body(accessor_id, description, policies_by_name, policies_by_id, nil)
      response = put('/token/' + accessor_id, body)
    rescue StandardError => e
      Puppet.warning("Unable to update token #{description} (Accessor ID: #{accessor_id}): #{e.message}")
      return nil
    end

    parse_policies(response['Policies'])
  end

  def delete_token(accessor_id)
    response = delete('/token/' + accessor_id)

    raise 'Consul API returned false as response' if response == 'false'
  rescue StandardError => e
    Puppet.warning("Unable to delete token #{accessor_id}: #{e.message}")
    nil
  end

  def parse_policies(response)
    return [] unless response

    policy_links = []
    response.each do |policy|
      policy_links.push(ConsulTokenPolicyLink.new(policy['ID'], policy['Name']))
    end

    policy_links
  end

  def encode_body(accessor_id, description, policies_by_name, policies_by_id, secret_id = nil)
    policies = []
    policies_by_name.each do |name|
      policies.push({ 'Name' => name })
    end

    policies_by_id.each do |id|
      policies.push({ 'ID' => id })
    end

    body = {}
    body.store('AccessorID', accessor_id)
    body.store('Description', description)
    body.store('Local', false)
    body.store('Policies', policies)

    body.store('SecretID', secret_id) if !secret_id.nil? && !secret_id.to_s.strip.empty?

    body
  end
end
