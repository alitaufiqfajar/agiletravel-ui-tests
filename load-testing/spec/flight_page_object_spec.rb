load File.dirname(__FILE__) + "/../test_helper.rb"
load File.dirname(__FILE__) + "/../load_test_helper.rb"

describe "Select Flights" do
  include TestHelper
  include LoadTestHelper

  before(:all) do
    @driver = $driver = Selenium::WebDriver.for(browser_type, browser_options)
    driver.get(site_url)
  end

  before(:each) do
  end

  after(:all) do
    driver.quit unless debugging?
  end

  it "[2] Return trip" do
    log_time("Visit Home Page") { driver.get(site_url) }
    driver.find_element(:id, "username").send_keys("agileway")
    driver.find_element(:id, "password").send_keys("testwise")
    log_time("Sign in") { driver.find_element(:name, "commit").click }

    flight_page = FlightPage.new(driver)
    flight_page.select_trip_type("oneway")
    flight_page.select_depart_from("Sydney")
    flight_page.select_arrive_at("New York")
    log_time("Select Flight") { flight_page.click_continue }
    expect(page_text).to include("2016-01-01 Sydney to New York")
    
    log_time("Sign out") { logout }
    
  end
end
