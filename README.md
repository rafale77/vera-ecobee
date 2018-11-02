# Ecobee Plugin adapted for openluup based on Watou's original Vera plugin.

Plugin will work on UI7 as well though I see no specific reason to not use the Appstore Released version which does not require your own developer's account. 
Note: As of 10/24/2018 no version prior to V2.1 will connect to the ecobee API. Please upgrade to V2.1 or above.

## Release Note: V2.11 (openLuup/UI7)

 - Improved connectivity resilience.

## Release Note: V2.1 (openLuup/UI7)

 - Implemented TLS v1.2 to support updates to the ecobee API from 10/23/18

## Release Note: V2.02 (openLuup/UI7)

 - Implemented API Key Retention: If connection is lost, clicking the getpin button even without the API key field will get you a new pin if you have previously been connected.

## Release Note: V2.0 (openLuup/UI7)

 - Split out Implemetation xml logic into L_Ecobee1.lua file
 - Integrated encrypted API file communication into main Lua file
 - Cosmetic refactoring with icons and layout for the main Ecobee device and Housemode device
 - Localized icons to reduce browser network traffic
 - Eliminated use of compressed json decoder
 
## Release Note: V1.8 (UI7/UI5) need to have previously installed from Vera apstore.

 - Cosmetic adjustments for UI7 Housemode

## Installation procedure:

- Download the content of this repository

- Make sure your Openluup/lua library supports https. For this You can go to the Misc/OsCommand tab under Altui and install LUASEC using this command "luarocks install luasec". This assumes that you also have luarocks installed. Follow the instructions here: https://github.com/luarocks/luarocks/wiki/Download

- Copy the content of the icons folder into the /#your Openluup folder#/icons.

- Copy the content of the repo into /#your Openluup folder#

- Create a new device in ALTUI using the D_Ecobee1.xml and I_Ecobee1.xml as your device files

- Now you need to create an ecobee developer account:
  1. Go to https://www.ecobee.com/developers/
  2. Login with your ecobee credentials.
  3. Accept the SDK agreement.
  4. Fill in the fields.
  5. Click save.
- Create an API Key:
  1. Login to the regular consumer portal, and in the main options menu there will be a new option Developer.
  2. Select the Developer option.
  3. Select Create New.
  4. Give your app a name (i.e Openluup)
  5. For Authorization method select ecobee PIN.
  6. You don’t need an Application Icon or Detailed Description.
  7. Click Create.
  8. Copy the API Key provided

- Establish Link between API and Openluup
  1. Paste the API key above into the API key field of the Ecobee device in Openluup and click "get pin"
  2. Use the pin obtained to create a new 
 

Please see reference documentation <a href="http://watou.github.io/vera-ecobee/">here</a>.
