# frozen_string_literal: true

require "mechanize"
require "scraperwiki"
require "active_support/core_ext/hash"

# Scrape horizon (solorient) site
module HorizonXml
  AUTHORITIES = {
    berrigan: {
      start_url: "http://datracking.berriganshire.nsw.gov.au/Horizon/logonGuest.aw?domain=horizondap#/home",
      state: "NSW"
    },
    leeton: {
      start_url: "http://datracking.leeton.nsw.gov.au/Horizon/logonGuest.aw?domain=horizondap#/home",
      state: "NSW"
    },
    cowra: {
      start_url:
        "https://mycouncil.solorient.com.au/Horizon/logonGuest.aw?domain=horizondap_cowra#/home",
      state: "NSW"
    },
    liverpool_plains: {
      start_url:
        "https://mycouncil.solorient.com.au/Horizon/logonGuest.aw?domain=horizondap_lpsc#/home",
      state: "NSW"
    },
    warrumbungle: {
      start_url: "https://mycouncil.warrumbungle.nsw.gov.au:6443/Horizon/logonGuest.aw?domain=horizondaplive#/home",
      state: "NSW",
      australian_proxy: true
    },
    walcha: {
      start_url:
        "https://mycouncil.solorient.com.au/Horizon/logonGuest.aw?domain=horizondap_walcha#/home",
      state: "NSW"
    },
    weddin: {
      start_url: "https://mycouncil.solorient.com.au/Horizon/logonGuest.aw?domain=horizondap_weddin#/home",
      state: "NSW"
    },
    maitland: {
      start_url: "https://myhorizon.maitland.nsw.gov.au/Horizon/logonOp.aw?e=" \
                  "FxkUAB1eSSgbAR0MXx0aEBcRFgEzEQE6F10WSz4UEUMAZgQSBwVHHAQdXD" \
                  "hUDDRATCUCXV8pHz4pHidmBBYGBUAWFQ0IAlVJAQQDGB9TEgIQDhp3ASUHBw%3D%3D",
      page_size: 100,
      disable_ssl_certificate_check: true,
      query_string:
        "FIND Applications " \
        "WHERE " \
        "Applications.ApplicationTypeID.IsAvailableOnline='Yes' AND " \
        "Applications.CanDisclose='Yes' AND " \
        "NOT(Applications.StatusName IN 'Pending', 'Cancelled') AND " \
        "MONTH(Applications.Lodged)=CURRENT_MONTH AND " \
        "YEAR(Applications.Lodged)=CURRENT_YEAR AND " \
        "Application.ApplicationTypeID.Classification='Application' " \
        "ORDER BY " \
        "Applications.Lodged DESC",
      query_name: "Application_LodgedThisMonth"
    }
  }.freeze

  def self.scrape_and_save(authority)
    scrape(authority) do |record|
      save(record)
    end
  end

  def self.scrape(authority)
    raise "Unexpected authority: #{authority}" unless AUTHORITIES.key?(authority)

    scrape_url(AUTHORITIES[authority]) do |record|
      yield record
    end
  end

  def self.log(record)
    puts "Saving record " + record["council_reference"] + ", " + record["address"]
  end

  def self.save(record)
    log(record)
    ScraperWiki.save_sqlite(["council_reference"], record)
  end

  def self.query_url(query_string:, query_name:, take:, start:, page_size:)
    "urlRequest.aw?" + {
      "actionType" => "run_query_action",
      "query_string" => query_string,
      "query_name" => query_name,
      "take" => take,
      "skip" => 0,
      "start" => start,
      "pageSize" => page_size
    }.to_query
  end

  def self.extract_total(page)
    xml = Nokogiri::XML(page.body)
    xml.xpath("//run_query_action_return/run_query_action_success/dataset/total").text.to_i
  end

  def self.extract_field(app, name)
    node = app.at(name)
    node["org_value"].strip if node
  end

  def self.scrape_page(page, info_url)
    xml = Nokogiri::XML(page.body)
    # We know about two different forms of this XML
    if xml.at("AccountNumber")
      council_reference_tag = "AccountNumber"
      address_tag = "Property"
      description_tag = "Description"
    else
      council_reference_tag = "EntryAccount"
      address_tag = "PropertyDescription"
      description_tag = "Details"
    end

    xml.search("row").each do |app|
      yield(
        "council_reference" => extract_field(app, council_reference_tag),
        "address" => extract_field(app, address_tag).split(", ")[0],
        "description" => extract_field(app, description_tag),
        "info_url" => info_url,
        "date_scraped" => Date.today.to_s,
        # TODO: Parse date based on knowledge of form
        "date_received" => DateTime.parse(extract_field(app, "Lodged")).to_date.to_s
      )
    end
  end

  def self.scrape_url(
    start_url:,
    page_size: 500,
    query_string:
      "FIND Applications " \
      "WHERE " \
      "MONTH(Applications.Lodged)=CURRENT_MONTH AND " \
      "YEAR(Applications.Lodged)=CURRENT_YEAR " \
      "ORDER BY " \
      "Applications.Lodged DESC",
    query_name: "SubmittedThisMonth",
    state: nil,
    australian_proxy: false,
    disable_ssl_certificate_check: false
  )
    agent = Mechanize.new
    agent.verify_mode = OpenSSL::SSL::VERIFY_NONE if disable_ssl_certificate_check
    
     if australian_proxy
      # On morph.io set the environment variable MORPH_AUSTRALIAN_PROXY to
      # http://morph:password@au.proxy.oaf.org.au:8888 replacing password with
      # the real password.
      agent.agent.set_proxy(ENV["MORPH_AUSTRALIAN_PROXY"])
    end
    
    agent.get(start_url)
    page = agent.get(
      query_url(
        query_string: query_string,
        query_name: query_name,
        take: 50,
        start: 0,
        page_size: page_size
      )
    )

    pages = extract_total(page) / page_size

    (0..pages).each do |i|
      if i.positive?
        page = agent.get(
          query_url(
            query_string: query_string,
            query_name: query_name,
            take: 50,
            start: i * page_size,
            page_size: page_size
          )
        )
      end
      scrape_page(page, start_url) do |record|
        record["address"] += " #{state}" if record["address"] && state

        yield record
      end
    end
  end
end
