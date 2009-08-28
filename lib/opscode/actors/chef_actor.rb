#
# Author:: Adam Jacob (<adam@opscode.com>)
# Copyright:: Copyright (c) 2009 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'json'
require 'chef'
require 'chef/client'
require 'chef/runner'
require 'chef/resource_collection'
require 'stringio'
require 'opscode/agent/config'
require 'tempfile'

# Quick and dirty hack
# Files in /sys have wrong size and File.read hangs inside EM.run { }
class File
  module FileExclusiveRead
    def read(*args)
      Thread.exclusive { super }
    end
  end
  class<<self
    include FileExclusiveRead
  end
end

module Opscode
  class ChefActor
    include Nanite::Actor

    class TeeStringLogger
      def initialize(intermediate_result_proc = nil)
        @buffer = StringIO.new
        @intermediate_result_proc = intermediate_result_proc
      end

      def write(message)
        STDOUT.write(message)
        @buffer.write(message)
        @intermediate_result_proc.call(message) if @intermediate_result_proc
      end

      def close
        write('--- LOG CLOSED')
      end

      def results
        @buffer.string
      end
    end
    
    expose :collection, :resource, :recipe, :converge
    def log_to_string(intermediate_result_proc = nil, &block)
      output = TeeStringLogger.new(intermediate_result_proc)
      Chef::Log.logger = nil
      Chef::Log.init(output)
      block.call
      Chef::Log.logger = nil
      output.results
    end

    def collection(payload, &mapper)
      node = Chef::Client.new.build_node
      lts = log_to_string(mapper) do
        resource_collection = payload 
        resource_collection.each { |r| r.instance_variable_set(:@node, node) }
        runner = Chef::Runner.new(node, resource_collection)
        runner.converge
      end
      { :log => lts, :resource => payload[:resource] } 
    end

    def resource(payload, &mapper)
      Chef::Log.level(:debug)
      client = Chef::Client.new
      client.build_node
      payload[:resource].instance_variable_set(:@node, client.node)
      lts = log_to_string(mapper) do
        payload[:resource].run_action(payload[:resource].action)
      end
      { :log => lts, :resource => payload[:resource] } 
    end

    def check_recipe(payload)
      orig_cookbook_path = Chef::Cookbook
      Chef::Log.level(:debug)
      client = Chef::Client.new
      client.build_node
      client.node
      tf = Tempfile.new("test-recipe")
      tf.write(payload)
      tf.close
      recipe = Chef::Recipe.new('temp', 'recipe', client.node)
      recipe.from_file(tf.path)
      ra = Array.new
      recipe.collection.each { |r| ra << r }
      { :resources => ra }
    end

    def recipe(payload, &mapper)
      tf = Tempfile.new("test-recipe")
      tf.write(payload)
      tf.close
      Chef::Log.level(:info)
      collection = nil 
      
      lts = log_to_string(mapper) do
        client = Chef::Client.new
        client.build_node
        client.node
        recipe = Chef::Recipe.new('temp', 'recipe', client.node)
        recipe.from_file(tf.path)
        runner = Chef::Runner.new(client.node, recipe.collection)
        runner.converge
        collection = recipe.collection
      end
      { :log => lts, :resources => collection }
    end

    def converge(payload, &mapper)
      log_to_string(mapper) do
        if payload && payload[:log_level]
          Chef::Log.level(payload[:log_level].to_sym)  rescue ArgumentError
        end
        client = Chef::Client.new
        client.run
      end
    end
  end
end
