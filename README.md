Ecobee Plugin adapted modified for Openluup based on Watou's free plugin.

Release Note: V2.0

 -Split out Implemetation xml logic into L_Ecobee1.lua file
 -Integrated encrypted API file communication into main Lua file
 -Cosmetic refactoring with icons and layout for the main Ecobee device and Housemode device
 -Localized icons to reduce browser network traffic
 -Eliminated use of compressed json decoder

Installation procedure:

- Download the content of this repository

- Make sure your Openluup/lua library supports https. For this You can go to the Misc/OsCommand tab under Altui and install LUASEC using this command "luarocks install luasec"

- Copy the content of the icons folder into the /#your Openluup folder#/icons.

- Copy the content of the src folder into /#your Openluup folder#

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
