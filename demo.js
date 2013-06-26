/* Demo initialisation script for mongodb */

// Change these values before running the script against your mongodb instance
// WARNING: The database specified in 'mongodb' will be DROPPED.

// Run this against your database using mongo:
//     mongo <HOST>:<PORT>/<DB> -u <USER> -p <PASS> demo.js

var mailhost = "YOUR.DOMAIN";
var demouser = "demo"; // will be demo@YOUR.DOMAIN
var demopass = "password";

var dbname = "m3mta";
var dbqueue = "queue";
var dbstore = "store";
var dbdomains = "domains";
var dbmailboxes = "mailboxes";

//------------------------------------------------------------------------------

print("Getting collection: " + dbqueue);
var queue = db.getCollection(dbqueue);
print("Removing items from collection: " + dbqueue);
queue.remove();

print("Getting collection: " + dbdomains);
var domains = db.getCollection(dbdomains);
print("Removing items from collection: " + dbdomains);
domains.remove();

print("Getting collection: " + dbmailboxes);
var mailboxes = db.getCollection(dbmailboxes);
print("Removing items from collection: " + dbmailboxes);
mailboxes.remove();

print("Getting collection: " + dbstore);
var store = db.getCollection(dbstore);
print("Removing items from collection: " + dbstore);
store.remove();

//------------------------------------------------------------------------------

print("Inserting demo domain: " + mailhost);
domains.insert({
    "domain": mailhost,
    "delivery": "local",
    "postmaster": "postmaster@" + mailhost
});

//------------------------------------------------------------------------------

print("Inserting demo mailbox: " + demouser + "@" + mailhost);
mailboxes.insert({
    "domain": mailhost,
    "mailbox": demouser,
    "username": demouser + "@" + mailhost,
    "password": demopass,
    "relay": 1,
    "delivery": {
        "path": "INBOX"
    },
    "validity": {
        "INBOX": 1,
        "Sent": 1,
        "Trash": 1,
        "INBOX/Subfolder": 1
    },
    "subscriptions": {
        "INBOX": 1,
        "Sent": 1,
        "Trash": 1,
        "INBOX/Subfolder": 1
    },
    "store": {
        "children": {
            "INBOX": {
                "seen": 0,
                "unseen": 0,
                "recent": 0,
                "nextuid": 1
            },            
            "Sent": {
                "seen": 0,
                "unseen": 0,
                "recent": 0,
                "nextuid": 1
            },
            "Trash": {
                "seen": 0,
                "unseen": 0,
                "recent": 0,
                "nextuid": 1
            },
            "INBOX/Subfolder": {
                "seen": 0,
                "unseen": 0,
                "recent": 0,
                "nextuid": 1
            }
        }
    }
});

//------------------------------------------------------------------------------

print("Inserting message into queue");
queue.insert({
        "created" : ISODate("2013-01-01T00:00:00Z"),
        "to" : [
                demouser + "@" + mailhost
        ],
        "from" : "postmaster@" + mailhost,
        "data" : "Message-ID: <51A66796.5070801@" + mailhost + ">\r\nDate: Tue, 01 Jan 2013 00:00:00 +0000\r\nFrom: Postmaster <postmaster@" + mailhost + ">\r\nUser-Agent: M3MTA\r\nMIME-Version: 1.0\r\nTo: " + demouser + "@" + mailhost + "\r\nSubject: MDA queue test\r\nContent-Type: text/plain; charset=ISO-8859-1; format=flowed\r\nContent-Transfer-Encoding: 7bit\r\n\r\nThank you for trying M3MTA.\r\n\r\nYour M3MTA installation is now complete.\r\n\r\nFor more information, visit http://github.com/ian-kent/m3mta",
        "id" : "il1k2GGTG5Zg0L7RNdn@" + mailhost,
        "helo" : "[localhost]"
});

//------------------------------------------------------------------------------

print("Demo data insert complete");