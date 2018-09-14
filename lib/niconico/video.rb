# -*- coding: utf-8 -*-
require 'json'
require 'niconico/deferrable'

class Niconico
  def video(video_id)
    login unless logged_in?
    Video.new(self, video_id)
  end

  class Video
    include Niconico::Deferrable

    deferrable :id, :title,
      :description, :description_raw,
      :url, :video_url, :type,
      :tags, :mylist_comment, :api_data

    def initialize(parent, video_id, defer=nil)
      @parent = parent
      @agent = parent.agent
      @fetched = false
      @thread_id = @id = video_id
      @page = nil
      @url = "#{Niconico::URL[:watch]}#{@id}"

      if defer
        preload_deffered_values(defer)
      else
        get()
      end
    end

    def economy?; @eco; end

    def post_heart_beat
      req = {
              "session" => {
                "id" => @dmc_session["id"],
                "recipe_id" => @token["recipe_id"],
                "content_id" => @token["content_ids"].first,
                "content_src_id_sets" => [
                  {
                    "content_src_ids" => [
                      {
                        "src_id_to_mux" => {
                          "video_src_ids" => [@video_src],
                          "audio_src_ids" => [@audio_src],
                        },
                      },
                    ],
                    "allow_subset" => "yes",
                  },
                ],
                "content_type" => "movie",
                "timing_constraint" => "unlimited",
                "keep_method": {
                  "heartbeat": {
                    "lifetime": 120000,
                    "onetime_token": "",
                    "deletion_timeout_on_no_stream": 0
                  },
                },
                "protocol" => req_protocol(),
                "play_seek_time" => 0,
                "play_speed" => 1,
                "play_control_range" => {
                  "max_play_speed" => 1,
                  "min_play_speed" => 1,
                },
                "content_uri" => @video_url,
                "session_operation_auth" => @dmc_session["session_operation_auth"],
                "content_auth" => @dmc_session["content_auth"],
                "runtime_info" => @dmc_session["runtime_info"],
                "client_info" => @dmc_session["client_info"],
                "created_time" => @dmc_session["created_time"],
                "modified_time" => @dmc_session["modified_time"],
                "priority" => @dmc_session["priority"],
                "content_route" => @dmc_session["content_route"],
                "version" => @dmc_session["version"],
                "content_status" => @dmc_session["content_status"],
              },
            }
      #puts req.to_json
      api_url = "#{@session_api["urls"].first["url"]}/#{@dmc_session["id"]}?_format=json&_method=PUT"
      @agent.post(api_url, req.to_json, {'Content-Type' => 'application/json'})
    end

    def req_protocol
      {
        "name" => "http",
        "parameters" => {
          "http_parameters" => {
            "method" => "GET",
            "parameters" => {
              "http_output_download_parameters" => {
                "file_extention" => "",
                "use_well_known_port" => "yes",
                "use_ssl" => "yes",
                "transfer_preset" => "standard2",
              },
            },
          },
        },
      }
    end

    def create_dmc_session(watch_data)
      @watch_data = JSON.parse(watch_data.attribute("data-api-data"))
      dmc_info = @watch_data["video"]["dmcInfo"]
      @session_api = dmc_info["session_api"]
      unless @session_api
        raise FailedCreateSession
      end
      token_text = @session_api["token"]

      @token = JSON.parse(token_text)

      @video_src = @token["videos"].first
      @audio_src = @token["audios"].first
      req = {
              "session" => {
                "recipe_id" => @token["recipe_id"],
                "content_id" => @token["content_ids"].first,
                "content_type" => "movie",
                "content_src_id_sets" => [
                  {
                    "content_src_ids" => [
                      "src_id_to_mux" => {
                        "video_src_ids" => [@video_src],
                        "audio_src_ids" => [@audio_src],
                      },
                    ],
                  },
                ],
                "timing_constraint" => "unlimited",
                "keep_method" => {
                  "heartbeat" => {
                    "lifetime" => @token["heartbeat_lifetime"],
                  },
                },
                "protocol" => req_protocol(),
                "content_uri" => "",
                "session_operation_auth" => {
                  "session_operation_auth_by_signature" => {
                    "token" => token_text,
                    "signature" => @session_api["signature"],
                  },
                },
                "content_auth" => {
                  "auth_type" => "ht2",
                  "content_key_timeout" => @token["content_key_timeout"],
                  "service_id" => @token["service_id"],
                  "service_user_id" => @token["service_user_id"],
                },
                "client_info" => {
                  "player_id" => @token["player_id"],
                },
                "priority" => @token["priority"],
              },
            }

      api_url = "#{@session_api["urls"].first["url"]}?_format=json"
      page = @agent.post(api_url, req.to_json, {'Content-Type' => 'application/json'})
      dmc = JSON.parse(page.body)
      @dmc_session = dmc["data"]["session"]
      @video_url = @dmc_session["content_uri"]
    end

    def get(options = {})
      begin
        @page = @agent.get(@url)
      rescue Mechanize::ResponseCodeError => e
        raise NotFound, "#{@id} not found" if e.message == "404 => Net::HTTPNotFound"
        raise e
      end

      if watch_data = @page.at("div#js-initial-watch-data")
        create_dmc_session(watch_data)
      else
        raise "not found div#js-initial-watch-data"
      end

      if api_data_node = @page.at("#watchAPIDataContainer")
        @api_data = JSON.parse(api_data_node.text())
        video_detail = @api_data["videoDetail"]
        @title ||= video_detail["title"] if video_detail["title"]
        @description ||= video_detail["description"] if video_detail["description"]
        @tags  ||= video_detail["tagList"].map{|e| e["tag"]}
      end

      t = @page.at("#videoTitle")
      @title ||= t.inner_text unless t.nil?
      d = @page.at("div#videoComment>div.videoDescription")
      @description ||= d.inner_html unless d.nil?

      @type = :mp4
      @tags ||= @page.search("#video_tags a[rel=tag]").map(&:inner_text)
      @mylist_comment ||= nil

      @fetched = true
      @page
    end

    def available?
      !!video_url
    end

    def get_video
      raise VideoUnavailableError unless available?

      unless block_given?
        warn "full request is memory use too much. please use yield block."
        raise UnsupportedFullRequest
      else

        offset = 0
        while true do
          begin
            # ハートビートしてても切れるのでResumeしながら落とす必要がある。
            post_heart_beat()

            terminate = offset + 9999999
            range = "bytes=#{offset}-#{terminate}"
            page = @agent.get(video_url, [], nil, { "Range" => range })
            bin = page.body.bytes

            # p page.response

            if page.response["content-length"].to_i != 10000000
              yield bin.pack('C*')
              break
            end

            offset = offset + bin.size
            yield bin.pack('C*')
          rescue Niconico::Video::FailedCreateSession => e
            raise e
          rescue Mechanize::ResponseReadError => e
            # continue
            sleep 10
          end
        end
      end
    end

    def get_video_by_other
      raise VideoUnavailableError unless available?
      warn "WARN: Niconico::Video#get_video_by_other is deprecated. use Video#video_cookie_jar or video_cookie_jar_file, and video_cookies with video_url instead. (Called by #{caller[0]})"
      {cookie: @agent.cookie_jar.cookies(URI.parse(@video_url)),
       url: video_url}
    end

    def video_cookies
      return nil unless available?
      @agent.cookie_jar.cookies(URI.parse(video_url))
    end

    def video_cookie_jar
      raise VideoUnavailableError unless available?
      video_cookies.map { |cookie|
        [cookie.domain, "TRUE", cookie.path,
         cookie.secure.inspect.upcase, cookie.expires.to_i,
         cookie.name, cookie.value].join("\t")
      }.join("\n")
    end

    def video_cookie_jar_file
      raise VideoUnavailableError unless available?
      Tempfile.new("niconico_cookie_jar_#{self.id}").tap do |io|
        io.puts(video_cookie_jar)
        io.flush
      end
    end

    def add_to_mylist(mylist_id, description='')
      @parent.nico_api.mylist_add(mylist_id, :video, @id, description)
    end

    def inspect
      "#<Niconico::Video: #{@id}.#{@type} \"#{@title}\"#{@eco ? " low":""}#{(fetched? && !@video_url) ? ' (unavailable)' : ''}#{fetched? ? '' : ' (defered)'}>"
    end

    class UnsupportedFullRequest < StandardError; end
    class FailedCreateSession < StandardError; end
    class NotFound < StandardError; end
    class VideoUnavailableError < StandardError; end
    class UnsupportedVideoError < StandardError; end
  end
end
