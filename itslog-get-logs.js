var util = require('util');
var AWS = require('aws-sdk');  
AWS.config.region = 'us-east-1';
var snsTopicARN = "arn:aws:sns:us-east-1:607456343589:sysdiag-alerts";

exports.handler = function(event, context, callback) {

    // Read options from the event.
    console.log("Reading options from event:\n", util.inspect(event, {depth: 5}));

    var s3Event = event.Records[0];

    var srcBucket = s3Event.s3.bucket.name;
    var srcEvent = s3Event.eventName;
    var time = s3Event.eventTime;

    var object = s3Event.s3.object.key;
    var size = Math.round((s3Event.s3.object.size)/1048576);

// Regular speed bucket
    var s3Url = "https://" + srcBucket + ".s3.amazonaws.com/" + object
    
// S3 accelerate bucket
// var s3Url = "https://" + srcBucket + ".s3-accelerate.amazonaws.com/" + object
// Example URL: https://itslog-blammo-001.s3.amazonaws.com/itslog/logs/abcd1234.tar.gz

    var msg =   "ITS-LOG: a sysdiagnose file was just uploaded. \r\n\r\n" +
                "Bucket: " + srcBucket + "\r\n" + 
                "Event: " + srcEvent + "\r\n" +
                "Object: " + object + "\r\n" +
                "Size: " + size + " MB\r\n" +
                "Time: " + time + "\r\n" + 
                "URL: " + s3Url + "\r\n" ;

    var sns = new AWS.SNS();

    sns.publish({
        Subject: "ITS-LOG: Sysdiagnose Uploaded",
        Message: msg,
        TopicArn: snsTopicARN
    }, 
    function(err, data) {
        if (err) {
            console.log(err.stack);
            return;
        }
        console.log(s3Event);
        console.log('push sent');
        console.log(s3Event);
        console.log(msg);
        context.done(null, 'Function Finished!');  
    });

}
