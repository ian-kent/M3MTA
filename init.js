/* Initialisation script for mongodb */

var conn = new Mongo();
var db = conn.getDB("mojosmtp");

db.dropDatabase();

//------------------------------------------------------------------------------
// Add some queue items for MDA testing
var queue = db.queue;
queue.insert({
        "_id" : ObjectId("51a666b2b7e1521979000000"),
        "created" : ISODate("2013-05-29T20:36:02Z"),
        "to" : [
                "iankent@gateway.dc4"
        ],
        "from" : "iankent@gateway.dc4",
        "data" : "Message-ID: <51A66796.5070801@gateway.dc4>\r\nDate: Wed, 29 May 2013 21:39:50 +0100\r\nFrom: Gateway Test <iankent@gateway.dc4>\r\nUser-Agent: Mozilla/5.0 (Windows NT 6.1; WOW64; rv:17.0) Gecko/20130328 Thunderbird/17.0.5\r\nMIME-Version: 1.0\r\nTo: iankent@gateway.dc4\r\nSubject: test 1\r\nContent-Type: text/plain; charset=ISO-8859-1; format=flowed\r\nContent-Transfer-Encoding: 7bit\r\n\r\ntest 1",
        "id" : "il1k2GGTG5Zg0L7RNdn@gateway.dc4",
        "helo" : "[192.168.100.64]"
});
queue.insert({
        "_id" : ObjectId("51a666beb7e1521979000001"),
        "created" : ISODate("2013-05-29T20:36:14Z"),
        "to" : [
                "iankent@gateway.dc4"
        ],
        "from" : "iankent@gateway.dc4",
        "data" : "Message-ID: <51A667A2.4030904@gateway.dc4>\r\nDate: Wed, 29 May 2013 21:40:02 +0100\r\nFrom: Gateway Test <iankent@gateway.dc4>\r\nUser-Agent: Mozilla/5.0 (Windows NT 6.1; WOW64; rv:17.0) Gecko/20130328 Thunderbird/17.0.5\r\nMIME-Version: 1.0\r\nTo: iankent@gateway.dc4\r\nSubject: test 2\r\nContent-Type: text/plain; charset=ISO-8859-1; format=flowed\r\nContent-Transfer-Encoding: 7bit\r\n\r\ntest 2",
        "id" : "mHj1H7JY6JJWcmGSGFz@gateway.dc4",
        "helo" : "[192.168.100.64]"
});

//------------------------------------------------------------------------------

var domains = db.domains;
domains.insert({
    "domain": "iankent.co.uk",
    "delivery": "relay"
});
domains.insert({
    "domain": "gateway.dc4",
    "delivery": "local"
});

//------------------------------------------------------------------------------

var mailboxes = db.mailboxes;
mailboxes.insert({
    // Should relay to mail.iankent.co.uk
    "domain": "iankent.co.uk",
    "mailbox": "ian.kent",
});
mailboxes.insert({
    // Should delivery locally
    "domain": "gateway.dc4",
    "mailbox": "iankent",
    "username": "iankent@gateway.dc4",
    "password": "test",
    "relay": 1,
    "delivery": {
        "uid": 1
    },
    "store": {
        "seen": 0,
        "unseen": 0,
        "children": {
            "INBOX": {
                "seen": 0,
                "unseen": 0,
            },            
            "Sent": {
                "seen": 0,
                "unseen": 0,
            },
            "Trash": {
                "seen": 0,
                "unseen": 0,
            }
        }
    }
});
