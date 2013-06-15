/* Initialisation script for mongodb */

var conn = new Mongo();
var db = conn.getDB("m3mta");

db.dropDatabase();

var queue = db.queue;
var domains = db.domains;
var mailboxes = db.mailboxes;
var store = db.store;

//------------------------------------------------------------------------------
// Add some queue items for MDA testing
queue.insert({
        "_id" : ObjectId("51a666b2b7e1521979000000"),
        "created" : ISODate("2013-05-29T20:36:02Z"),
        "to" : [
                "iankent@iankent.no-ip.biz"
        ],
        "from" : "iankent@iankent.no-ip.biz",
        "data" : "Message-ID: <51A66796.5070801@iankent.no-ip.biz>\r\nDate: Wed, 29 May 2013 21:39:50 +0100\r\nFrom: Gateway Test <iankent@iankent.no-ip.biz>\r\nUser-Agent: Mozilla/5.0 (Windows NT 6.1; WOW64; rv:17.0) Gecko/20130328 Thunderbird/17.0.5\r\nMIME-Version: 1.0\r\nTo: iankent@iankent.no-ip.biz\r\nSubject: test 1\r\nContent-Type: text/plain; charset=ISO-8859-1; format=flowed\r\nContent-Transfer-Encoding: 7bit\r\n\r\ntest 1",
        "id" : "il1k2GGTG5Zg0L7RNdn@iankent.no-ip.biz",
        "helo" : "[192.168.100.64]"
});
queue.insert({
        "_id" : ObjectId("51a666beb7e1521979000001"),
        "created" : ISODate("2013-05-29T20:36:14Z"),
        "to" : [
                "iankent@iankent.no-ip.biz"
        ],
        "from" : "iankent@iankent.no-ip.biz",
        "data" : "Message-ID: <51A667A2.4030904@iankent.no-ip.biz>\r\nDate: Wed, 29 May 2013 21:40:02 +0100\r\nFrom: Gateway Test <iankent@iankent.no-ip.biz>\r\nUser-Agent: Mozilla/5.0 (Windows NT 6.1; WOW64; rv:17.0) Gecko/20130328 Thunderbird/17.0.5\r\nMIME-Version: 1.0\r\nTo: iankent@iankent.no-ip.biz\r\nSubject: test 2\r\nContent-Type: text/plain; charset=ISO-8859-1; format=flowed\r\nContent-Transfer-Encoding: 7bit\r\n\r\ntest 2",
        "id" : "mHj1H7JY6JJWcmGSGFz@iankent.no-ip.biz",
        "helo" : "[192.168.100.64]"
});

//------------------------------------------------------------------------------

domains.insert({
    "domain": "iankent.co.uk",
    "delivery": "relay"
});
domains.insert({
    "domain": "iankent.no-ip.biz",
    "delivery": "local"
});

//------------------------------------------------------------------------------

mailboxes.insert({
    // Should delivery locally
    "domain": "iankent.no-ip.biz",
    "mailbox": "iankent",
    "username": "iankent@iankent.no-ip.biz",
    "password": "test",
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
                "unseen": 1,
                "recent": 1,
                "nextuid": 2
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
                "unseen": 1,
                "recent": 1,
                "nextuid": 2
            }
        }
    }
});

//------------------------------------------------------------------------------

store.insert({
    "_id" : ObjectId("51b3150732dd005410000000"),
    "flags" : [
            "\\Unseen",
            "\\Recent"
    ],
    "uid" : 1,
    "path" : "INBOX",
    "mailbox" : {
            "domain" : "iankent.no-ip.biz",
            "user" : "iankent"
    },
    "message" : {
            "body" : "test",
            "headers" : {
                    "Received" : "from [192.168.100.64] by  (SomeMail)\nid il1k2GGTG5Zg0L7RNdn@iankent.no-ip.biz;",
                    "Subject" : "Inbox test",
                    "MIME-Version" : "1.0",
                    "User-Agent" : "Mozilla/5.0 (Windows NT 6.1; WOW64; rv:17.0) Gecko/20130509 Thunderbird/17.0.6",
                    "Date" : "Sat, 08 Jun 2013 12:31:10 +0100",
                    "Message-ID" : "<51D125FE.5080000@iankent.no-ip.biz>",
                    "Content-Type" : "text/plain; charset=ISO-8859-1; format=flowed",
                    "To" : "iankent@iankent.no-ip.biz",
                    "Content-Transfer-Encoding" : "7bit",
                    "From" : "Gateway Test <iankent@iankent.no-ip.biz>"
            },
            "size" : NumberLong(387)
    }
}); 

store.insert({
    "_id" : ObjectId("51b3150732dd005410001200"),
    "flags" : [
            "\\Unseen",
            "\\Recent"
    ],
    "uid" : 1,
    "path" : "INBOX/Subfolder",
    "mailbox" : {
            "domain" : "iankent.no-ip.biz",
            "user" : "iankent"
    },
    "message" : {
            "body" : "test",
            "headers" : {
                    "Received" : "from [192.168.100.64] by  (SomeMail)\nid il1k2GGTG5Zg0L7RNdn@iankent.no-ip.biz;",
                    "Subject" : "Subfolder test",
                    "MIME-Version" : "1.0",
                    "User-Agent" : "Mozilla/5.0 (Windows NT 6.1; WOW64; rv:17.0) Gecko/20130509 Thunderbird/17.0.6",
                    "Date" : "Sat, 08 Jun 2013 12:31:10 +0100",
                    "Message-ID" : "<51B316AC.5080000@iankent.no-ip.biz>",
                    "Content-Type" : "text/plain; charset=ISO-8859-1; format=flowed",
                    "To" : "iankent@iankent.no-ip.biz",
                    "Content-Transfer-Encoding" : "7bit",
                    "From" : "Gateway Test <iankent@iankent.no-ip.biz>"
            },
            "size" : NumberLong(387)
    }
}); 