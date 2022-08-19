// Source: https://stackoverflow.com/questions/30651502/how-to-get-contents-of-a-text-file-from-aws-s3-using-a-lambda-function
// The trigger for this function is the S3 bucket
// Event type: s3:ObjectCreated:*
// Prefix: itslog/surveys/

var util = require('util')
var AWS = require('aws-sdk');
var s3 = new AWS.S3();

// Added these two lines to identify the bucket and SNS topic
AWS.config.region = 'us-east-1';
var snsTopicARN = "arn:aws:sns:us-east-1:607456343589:sysdiag-alerts";

exports.handler = function(event, context, callback) {
    
    // Retrieve the bucket & key for the uploaded S3 object that
    // caused this Lambda function to be triggered
    var Bucket = event.Records[0].s3.bucket.name;
    var Key = decodeURIComponent(event.Records[0].s3.object.key.replace(/\+/g, ' '));


// NOTE:
// Added these six lines

    var s3Event = event.Records[0];
    var srcBucket = s3Event.s3.bucket.name;
    var srcEvent = s3Event.eventName;
    var srcTime = s3Event.eventTime;
    var srcObject = s3Event.s3.object.key;
  
    // Retrieve the object
    s3.getObject({ Bucket, Key }, function(err, data) {
        if (err) {
            console.log(err, err.stack);
            callback(err);
        } else {

// NOTE: Added srcBody line
            var srcBody = data.Body.toString("ascii");

            console.log("Raw text:\n" + data.Body.toString('ascii'));
            callback(null, null);
        }
        
        // NOTE: Added these lines to construct the message 
        // and send the notification via SNS.

        var msg =   "ITS-LOG: a Survey Response was recorded. \r\n\r\n" +
                    "Bucket: " + srcBucket + "\r\n" +
                    "Filename: " + srcObject + "\r\n" +
                    "Time Sent:" + srcTime + "\r\n" +
                    "Survey responses: \r\n" +
                    "---------------------------- \r\n" +
                    srcBody;
                  
        var sns = new AWS.SNS();
        
        sns.publish({
          Subject: "ITS-LOG: Survey Recorded",
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
          
    });
};

