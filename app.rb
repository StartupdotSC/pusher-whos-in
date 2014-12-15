require 'rubygems'
require 'sinatra'
require 'haml'
require 'json'
require "gravatar-ultimate"
require './lib/render_partial'
require 'pusher'
require 'mongo'
require 'faraday'

Pusher.url = ENV["PUSHER_URL"]

helpers do
  def protected!
    return if authorized?
    headers['WWW-Authenticate'] = 'Basic realm="Restricted Area"'
    halt 401, "Not authorized\n"
  end

  def authorized?
    @auth ||=  Rack::Auth::Basic::Request.new(request.env)
    @auth.provided? and @auth.basic? and @auth.credentials and @auth.credentials == ['admin', ENV["PUSHER_URL"]]
  end
end

include Mongo

configure do
  if !ENV['MONGOLAB_URI']
    conn = MongoClient.new("localhost", 27017)
    set :mongo_connection, conn
    set :mongo_db, conn.db('whos_in')
  else
    mongo_uri = ENV['MONGOLAB_URI']
    db_name = mongo_uri[%r{/([^/\?]+)(\?|$)}, 1]
    client = MongoClient.from_uri(mongo_uri)
    db = client.db(db_name)
    set :mongo_connection, client
    set :mongo_db, db
  end

  # Configure Slack Integration
  set :slack_webhook_url, ENV['SLACK_WEBHOOK_URL']
end


# Set Sinatra variables
set :app_file, __FILE__
set :root, File.dirname(__FILE__)
set :views, 'views'
set :public_folder, 'public'

# Database of users

set :people, settings.mongo_db['users']

# Application routes
get '/' do
  haml :index, :layout => :'layouts/application'
end

post '/people' do
  protected!
  location = params[:location]
  addresses = JSON.parse(request.body.read).map(&:values).flatten
  people = update_people_from addresses, location
  Pusher['people_channel'].trigger('people_event', people)
end

post '/users/new' do
  user_data = JSON.parse(request.body.read)
  user_data["gravatar"], user_data["last_seen"] = Gravatar.new(user_data["email"]).image_url, Time.new(0)
  settings.mongo_db['users'].insert user_data
  {success: 200}.to_json
end

def status_by addresses, location
  Proc.new { |person|
    if is_included_in_list?(person, addresses)
      set_presence_of(person, true, location)
    else
      if inactive_for_ten_minutes?(person)
        set_presence_of(person, false)
      end
    end
  }
end

def is_included_in_list? person, addresses
  addresses.include? person["mac"].upcase
end

def inactive_for_ten_minutes? person
  Time.now >= (person["last_seen"] + 10*60)
end

def set_presence_of person, status, location=nil
  if person['present'] == false && status
    notify_slack person, true
  elsif person['present'] == true && !status
    notify_slack person, false
  end

  insertion = status ? {"last_seen" => Time.now, "present" => true, "location" => location} : {"present" => false }
  settings.people.update({"_id" => person["_id"]}, {"$set" => insertion})
end

def update_people_from addresses, location
  settings.people.find.map(&status_by(addresses, location))
  return settings.people.find.to_a
end

def notify_slack person, present
  if settings.slack_webhook_url
    if present
      payload = { text: "#{person['name']} has arrived at #{person['location']}!" }
    else
      payload = { text: "#{person['name']} has left #{person['location']}." }
    end

    slack_connection.post settings.slack_webhook_url, payload.to_json
  end
end

private

def slack_connection
  Faraday.new do |faraday|
    faraday.headers['Content-Type'] = 'application/json'
    faraday.headers['Content-Encoding'] = 'UTF-8'
    faraday.adapter Faraday.default_adapter
  end
end
