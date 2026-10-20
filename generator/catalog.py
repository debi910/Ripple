"""Synthetic catalogue, store network and identity building blocks.

Every brand and product name here is invented. Nothing is drawn from a real
retailer, so the generated world is free to publish under the MIT licence.
"""

# (category, substitute group, base product, sizes, price range in INR, perishable)
PRODUCT_GROUPS = [
    ("Dairy", "toned_milk", "Toned Milk", ["500ml", "1L"], (28, 68), True),
    ("Dairy", "curd", "Fresh Curd", ["400g", "1kg"], (35, 95), True),
    ("Dairy", "paneer", "Malai Paneer", ["200g", "500g"], (80, 210), True),
    ("Dairy", "butter", "Salted Butter", ["100g", "500g"], (55, 280), False),
    ("Bakery", "white_bread", "White Bread", ["400g", "700g"], (35, 60), True),
    ("Bakery", "brown_bread", "Brown Bread", ["400g"], (45, 65), True),
    ("Bakery", "pav", "Ladi Pav", ["6 pcs", "12 pcs"], (25, 50), True),
    ("Eggs", "eggs", "Farm Eggs", ["6 pcs", "12 pcs", "30 pcs"], (48, 220), True),
    ("Fruits", "banana", "Robusta Banana", ["6 pcs", "12 pcs"], (35, 80), True),
    ("Fruits", "apple", "Shimla Apple", ["4 pcs", "1kg"], (90, 240), True),
    ("Vegetables", "onion", "Onion", ["500g", "1kg", "2kg"], (25, 110), True),
    ("Vegetables", "tomato", "Hybrid Tomato", ["500g", "1kg"], (20, 80), True),
    ("Vegetables", "potato", "Potato", ["1kg", "2kg"], (30, 90), True),
    ("Vegetables", "coriander", "Coriander Bunch", ["100g"], (10, 25), True),
    ("Staples", "atta", "Whole Wheat Atta", ["1kg", "5kg", "10kg"], (55, 520), False),
    ("Staples", "basmati", "Basmati Rice", ["1kg", "5kg"], (110, 760), False),
    ("Staples", "toor_dal", "Toor Dal", ["500g", "1kg"], (80, 190), False),
    ("Staples", "sunflower_oil", "Sunflower Oil", ["1L", "5L"], (140, 790), False),
    ("Staples", "sugar", "Refined Sugar", ["1kg", "5kg"], (48, 240), False),
    ("Snacks", "potato_chips", "Salted Potato Chips", ["52g", "130g"], (20, 50), False),
    ("Snacks", "namkeen", "Aloo Bhujia", ["200g", "400g", "1kg"], (55, 260), False),
    ("Snacks", "cookies", "Butter Cookies", ["75g", "200g"], (25, 90), False),
    ("Snacks", "instant_noodles", "Masala Instant Noodles", ["70g", "4 pack"], (14, 60), False),
    ("Beverages", "cola", "Cola", ["300ml", "750ml", "2L"], (20, 95), False),
    ("Beverages", "orange_juice", "Orange Juice", ["200ml", "1L"], (25, 130), False),
    ("Beverages", "tea", "Assam Tea", ["250g", "500g", "1kg"], (120, 520), False),
    ("Beverages", "coffee", "Instant Coffee", ["50g", "100g", "200g"], (110, 520), False),
    ("Beverages", "packaged_water", "Mineral Water", ["1L", "5L"], (20, 80), False),
    ("Personal Care", "shampoo", "Anti-Dandruff Shampoo", ["180ml", "340ml"], (140, 380), False),
    ("Personal Care", "toothpaste", "Herbal Toothpaste", ["100g", "150g"], (55, 120), False),
    ("Personal Care", "soap", "Sandal Bath Soap", ["3x100g", "4x125g"], (90, 220), False),
    ("Personal Care", "sanitary_pads", "Ultra Thin Pads", ["8 pcs", "16 pcs", "30 pcs"], (45, 320), False),
    ("Baby Care", "diapers", "Baby Diapers M", ["20 pcs", "56 pcs"], (320, 1150), False),
    ("Baby Care", "baby_wipes", "Baby Wipes", ["72 pcs"], (120, 240), False),
    ("Household", "dish_liquid", "Lemon Dish Liquid", ["500ml", "1L"], (95, 210), False),
    ("Household", "detergent", "Matic Detergent", ["1kg", "2kg"], (190, 520), False),
    ("Household", "floor_cleaner", "Floor Cleaner", ["500ml", "1L"], (95, 220), False),
    ("Household", "garbage_bags", "Garbage Bags", ["30 pcs"], (80, 140), False),
    ("Frozen", "frozen_peas", "Green Peas", ["500g", "1kg"], (65, 180), True),
    ("Frozen", "ice_cream", "Vanilla Ice Cream", ["500ml", "1L"], (90, 260), True),
    ("Pharma", "paracetamol", "Paracetamol 650", ["15 tabs"], (30, 35), False),
    ("Pharma", "ors", "ORS Electrolyte", ["4 sachets", "1L"], (45, 120), False),
    ("Pet", "dog_food", "Adult Dog Food", ["1.2kg", "3kg"], (320, 980), False),
]

BRANDS = [
    "Nandi Farms", "Gokul Fresh", "Sahyadri", "Vrindavan", "Kaveri Valley", "Himgiri",
    "Lotus Leaf", "Green Basket", "Dhara Gold", "Sunbeam", "Tulsi Grove", "Monsoon",
    "Kesar Kitchen", "Neelgiri", "Arka", "Pinewood", "Saffron Lane", "Chandra",
    "Banyan", "Peacock", "Coral Bay", "Ashoka Pure", "Indus Daily", "Meadow Hill",
]

CITIES = [
    ("Bengaluru", ["Koramangala", "Indiranagar", "HSR Layout", "Whitefield"], "5600"),
    ("Mumbai", ["Andheri West", "Powai", "Bandra", "Thane"], "4000"),
    ("Delhi NCR", ["Saket", "Dwarka", "Gurugram Sec 45", "Noida Sec 62"], "1100"),
    ("Hyderabad", ["Gachibowli", "Madhapur", "Kondapur"], "5000"),
    ("Pune", ["Baner", "Kothrud", "Viman Nagar"], "4110"),
]

FIRST_NAMES = [
    "Aarav", "Vivaan", "Aditya", "Vihaan", "Arjun", "Sai", "Reyansh", "Ayaan", "Krishna",
    "Ishaan", "Rahul", "Rohit", "Amit", "Suresh", "Vikram", "Karthik", "Nikhil", "Manoj",
    "Sandeep", "Rajesh", "Pranav", "Harsh", "Kunal", "Siddharth", "Anil", "Deepak",
    "Saanvi", "Ananya", "Diya", "Aadhya", "Pari", "Isha", "Priya", "Sneha", "Pooja",
    "Neha", "Kavya", "Riya", "Shreya", "Anjali", "Divya", "Meera", "Lakshmi", "Swati",
    "Nisha", "Tanvi", "Aishwarya", "Debi", "Sunita", "Rekha", "Fatima", "Zoya", "Imran",
    "Arif", "Joseph", "Mary", "Thomas", "Gurpreet", "Harpreet", "Simran", "Mohan",
]

LAST_NAMES = [
    "Sharma", "Verma", "Gupta", "Kumar", "Singh", "Patel", "Shah", "Reddy", "Rao", "Nair",
    "Iyer", "Menon", "Pillai", "Das", "Bose", "Banerjee", "Mukherjee", "Chatterjee",
    "Joshi", "Kulkarni", "Deshpande", "Patil", "Jain", "Agarwal", "Mehta", "Khan",
    "Sheikh", "Fernandes", "D'Souza", "Gill", "Sandhu", "Yadav", "Mishra", "Pandey",
    "Tiwari", "Samal", "Mohanty", "Naidu", "Hegde", "Chopra",
]

EMAIL_DOMAINS = ["gmail.com", "gmail.com", "gmail.com", "yahoo.co.in", "outlook.com",
                 "rediffmail.com", "hotmail.com", "icloud.com"]
WORK_DOMAINS = ["infosys-mail.test", "corpmail.test", "startup.test", "bank-staff.test",
                "college.edu.test"]

CHANNELS = ["app", "web", "store_loyalty", "whatsapp"]
