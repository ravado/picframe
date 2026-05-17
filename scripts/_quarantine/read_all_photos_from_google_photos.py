import requests

BASE_URL = "https://photoslibrary.googleapis.com/v1/mediaItems:search"
ACCESS_TOKEN = "REAL_TOKEN"

headers = {
    "Authorization": f"Bearer {ACCESS_TOKEN}",
    "Content-Type": "application/json",
}

data = {
    "albumId": "AP0kFAQZHaVWr3kPKHdnBC1pueDHIFJ-vGqgAYxl6DBzwjhocIdRvBs7IPmpoESGdHJ6yghr2yUY",
    "pageSize": 100  # You can set this to any value up to 100, which is the max allowed by the API.
}

while True:
    response = requests.post(BASE_URL, headers=headers, json=data)
    
    if response.status_code != 200:
        print("Error:", response.json().get("error", {}).get("message", "Unknown error"))
        break
    
    response_data = response.json()

    for media_item in response_data.get('mediaItems', []):
        print(media_item.get('filename', 'No filename'))

    next_page_token = response_data.get('nextPageToken')
    if not next_page_token:
        break

    data['pageToken'] = next_page_token
