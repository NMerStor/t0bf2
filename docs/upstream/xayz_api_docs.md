Enterprise API Documentation
Integrate Xayz Premium Obfuscation directly into your Discord Bots, CI/CD pipelines, or external web applications. Our RESTful API is blazing fast, Serverless-ready, and equipped with Anti-Bot protection mechanisms.

Global Configuration
Base URL	https://luaob.vercel.app
Content-Type	application/json or multipart/form-data
Rate Limit	100 requests per IP per hour (Recommended)
*Note: Ensure your User-Agent does not contain words like "bot", "curl", or "postman", as our WAF (Web Application Firewall) will block it automatically.

1. Obfuscate Raw Text Code
POST /api/obfuscate

Use this endpoint to send raw string Lua code via JSON body.

Request Body Parameters
Field	Type	Required	Description
code	String	Yes	The raw Lua script you want to obfuscate.
targetMode	String	No	roblox (default) or standard.
Example Request (Node.js / Axios)
const axios = require('axios');

axios.post('https://luaob.vercel.app/api/obfuscate', {
    code: 'print("Hello World")',
    targetMode: 'roblox'
}, {
    headers: { 'User-Agent': 'MyCustomApp/1.0' } // Custom UA to bypass anti-bot
}).then(res => {
    console.log(res.data.result);
}).catch(err => console.error(err));
Success Response (200 OK)
{
  "success": true,
  "result": "-- [[ Xayz Obfuscator Premium ]] --\nlocal _IlIllI = ..."
}
2. Obfuscate Uploaded File
POST /api/obfuscate/file

Use this endpoint to upload entire .lua files via FormData. Ideal for processing large scripts without stringifying them manually.

Request FormData Parameters
Field	Type	Required	Description
file	File (Blob)	Yes	The Lua file to be processed. (Max 5MB)
targetMode	String	No	roblox or standard.
Example Request (Python)
import requests

url = "https://luaob.vercel.app/api/obfuscate/file"
files = {'file': open('myscript.lua', 'rb')}
data = {'targetMode': 'roblox'}
headers = {'User-Agent': 'Mozilla/5.0'}

response = requests.post(url, files=files, data=data, headers=headers)
print(response.json()['result'])
Error Handling
If the API encounters an issue, it will return a 400 or 500 status code with a descriptive JSON object.

// Example 400 Bad Request
{
  "error": "Invalid content! This does not look like Lua code."
}