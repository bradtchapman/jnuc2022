#!/bin/bash

## REMEMBER TO SET THE 3 SCRIPT PARAMETERS IN JAMF:
## PARAMETER 4 = AWS ACCESS KEY
## PARAMETER 5 = AWS SECRET KEY
## PARAMETER 6 = BUCKET@REGION

# The /var/tmp folder must exist, or the script will abort immediately.

cd /var/tmp || exit 1

initScriptParameters() {
	
	# JAMF SCRIPT PARAMETERS
	
	aws_ak="$4"													# access key
	aws_sk="$5"													# secret key
	bucket="$(echo "$6" | awk 'BEGIN{FS="@"}{print $1}')"		# bucket name
	region="$(echo "$6" | awk 'BEGIN{FS="@"}{print $2}')"		# region name
	
	swd_commands="/var/tmp/swd_run.log"
	timeStamp=$(date -j +"%Y%m%d-%H%M%S")
	timeStampEpoch=$(date -j +"%s")
	secondsForSurvey="30"
	currentUser=$(ls -la /dev/console | awk '{ print $3 }')
	serialNumber=$(system_profiler SPHardwareDataType | awk -F":" '/Serial Number/ { gsub(/ /,""); print $2 }')
	modelID=$(system_profiler SPHardwareDataType | awk '/Model Identifier/ { print $3 }' | tr ',' '_')
	macOSvers=$(sw_vers | awk '/ProductVersion/ { print $2 }')
	macOSbuild=$(sw_vers | awk '/BuildVersion/ { print $2 }')
	sysDiagArchive="itslog_${timeStamp}_${currentUser}_${serialNumber}_${modelID}_${macOSvers}_${macOSbuild}"
	sysDiagTarball="$sysDiagArchive.tar.gz"
	surveyResponse="itslog_${timeStamp}_${currentUser}_${serialNumber}_${modelID}_${macOSvers}_${macOSbuild}.txt"
	mini_window_launched=false
	surveyStageDone=false
	surveyEmpty=false
	
}


# This function writes data to the swiftDialog command log
swd_echo() {
	echo "$1" | tee -a "$swd_commands"
}


# This function generates the AWS v4 Signatures & checksums required for upload.
#
# ADAPTED FROM THIS SCRIPT:
# https://very.busted.systems/shell-script-for-S3-upload-via-curl-using-AWS-version-4-signatures

generate_aws_keys() {

	srcfile=$1
	targfile=$2
	acl="public-read"
	md5="$(openssl md5 -binary "$srcfile" | openssl base64)"
	
	# Create signature if not public upload.
	
	key_and_sig_args=''
	if [ "$aws_ak" != "" ] && [ "$aws_sk" != "" ]; then
		
		# Need current and file upload expiration date. Handle GNU and BSD date command style to get tomorrow's date.
		date="$(date -u +%Y%m%dT%H%M%SZ)"
		expdate="$(if ! date -v+1d +%Y-%m-%d 2>/dev/null; then date -d tomorrow +%Y-%m-%d; fi)"
		expdate_s="$(echo "$expdate" | sed s/-//g)" # without dashes, as we need both formats below
		service='s3'
		
		echo "Fields generated: date: $date - expdate: $expdate - expdate_s: $expdate_s - service: $service"
		
			# Generate policy and sign with secret key following AWS Signature version 4, below
			p=$(cat <<-POLICY | openssl base64
			{ "expiration": "${expdate}T12:00:00.000Z",
				"conditions": [
				{"acl": "$acl" },
				{"bucket": "$bucket" },
				["starts-with", "\$key", ""],
				["starts-with", "\$content-type", ""],
				["content-length-range", 1, $(ls -l -H "$srcfile" | awk '{print $5}' | head -1)],
				{"content-md5": "$md5" },
				{"x-amz-date": "$date" },
				{"x-amz-credential": "$aws_ak/$expdate_s/$region/$service/aws4_request" },
				{"x-amz-algorithm": "AWS4-HMAC-SHA256" }
				]
			}
			POLICY
		)
			
			echo "The value of POLICY is $p"
			
			# AWS4-HMAC-SHA256 signature
			s=$(echo -n "$expdate_s"   | openssl sha256 -hmac "AWS4$aws_sk"           -hex | sed 's/(stdin)= //')
			s=$(echo -n "$region"      | openssl sha256 -mac HMAC -macopt hexkey:"$s" -hex | sed 's/(stdin)= //')
			s=$(echo -n "$service"     | openssl sha256 -mac HMAC -macopt hexkey:"$s" -hex | sed 's/(stdin)= //')
			s=$(echo -n "aws4_request" | openssl sha256 -mac HMAC -macopt hexkey:"$s" -hex | sed 's/(stdin)= //')
			s=$(echo -n "$p"           | openssl sha256 -mac HMAC -macopt hexkey:"$s" -hex | sed 's/(stdin)= //')
			
			key_and_sig_args="-F X-Amz-Credential=$aws_ak/$expdate_s/$region/$service/aws4_request -F X-Amz-Algorithm=AWS4-HMAC-SHA256 -F X-Amz-Signature=$s -F X-Amz-Date=${date}"
			
		fi
	
} 

launch_mini_window() {
	
	/usr/local/bin/dialog -d --commandfile "$swd_commands" \
	--mini --moveable --position center --icon "$icon" \
	--title "ITS-LOG: Upload in progress..." \
	--message "This window will close when all files are collected and uploaded." \
	--progress &
	swd_mini_PID=$!
	
	mini_window_launched=true
	surveyStageDone=true
	
	
}

##### SEQUENTIAL / RUNTIME FUNCTIONS
#
##### STAGE 1: Dialog Launches
#

launchSurveyWindow() {
	
	position="center"
	quitkey="x"
	dialog_width="700"
	dialog_height="600"
	title="ITS-LOG: Crash Survey"
	titlefont="color=#ff6600,weight=bold,size=24"
	message="## Oh no! \n #### We're sorry that your Mac is having a problem.  Please tell us a little more about the most recent crash or issue that occurred. \n ##### If you're done, click [OK] ; processing will continue in the background. \n ###### NOTE: This tool collects diagnostic data from your Mac that will be transmitted to your IT department, who may require forwarding to Apple for additional analysis."
	messagefont="weight=light,size=18"
	icon="/var/tmp/sad-mac-8bit.png"
	iconsize=128
	feedbackSurveyJSON='{ "selectitems" : [ { "title" : "Type of issue?", "values" : ["System crash or unexpected reboot","System is slow or unresponsive","One app crashed unexpected","Something else not on this list"] }, { "title" : "How frequently?", "values" : ["Immediately","After a few minutes","After a few hours","After a few days","It varies","It comes and goes","Unsure"] }, { "title" : "Last occurrence?", "values" : ["It is happening now","Less than 20 minutes ago","Less than 1 hour ago","1-6 hours ago","6-12 hours ago","12-24 hours ago","More than 24 hours ago","Unsure"] } ] }'
	/usr/local/bin/dialog -d --moveable --commandfile "$swd_commands" --quitkey "$quitkey" \
	--width "$dialog_width" --height "$dialog_height" --position "$position" \
	--title "$title" --titlefont "$titlefont" --icon "$icon" --iconsize "$iconsize" \
	--message "$message" --messagefont "$messagefont" \
	--textfield "Describe in detail:",editor,required \
	--textfield "What is your UID?",required,regex="^\d{9}$",regexerror="Company UID must be exactly 9 digits." \
	--jsonstring "$feedbackSurveyJSON" \
	--progress \
	| tee "$surveyResponse" &
	swd_survey_PID=$!
	
	/usr/bin/afplay -v 1.0 /var/tmp/itslog-crash-mac-8bit.m4a &
	
	sleep 1

}


#
##### STAGE 2: SYSDIAGNOSE COLLECTION
#

generateSysdiagnose() {
	
	/usr/bin/sysdiagnose -b -n -u -f /var/tmp -A "$sysDiagArchive" | cat &
	
	swd_echo "progresstext: Gathering logs (about 3-5 minutes) ..."
	
	sleep 5
	
	while [[ -n $(pgrep "sysdiagnose_helper") ]]
	do
		# Keep checking until the sysdiagnose utility has finished.  "Sysdiagnose is still running..."
		
		# If user finishes the survey before curl or sysdiagnose are completed...
		# Launch the mini window to keep them informed.
		
		if [[ -z $(ps -ax $swd_survey_PID | tail +2) && $mini_window_launched == false ]]
		then
			launch_mini_window
			swd_echo "progresstext: Gathering logs (about 3-5 minutes) ..."
		fi
		
		sleep 1
		
	done

	# Copy additional files intp the archive folder before compression   
	
	cp /var/log/jamf.log "$sysDiagArchive/"
	# cp /var/log/somefile1.log
	# cp /var/log/somefile2.log

	/usr/bin/tar -czf "$sysDiagTarball" "$sysDiagArchive/" &
	tarPID=$!
	
	echo "PID of tar is $tarPID"
	
	swd_echo "progresstext: Compressing logs and preparing to upload."
	
	sleep 5
	
	while [[ -n $(ps -ax $tarPID | tail +2) ]]
	do
		# echo "tar is still balling..."
		
		# If user finishes the survey before curl or sysdiagnose are completed...
		# Launch the mini window to keep them informed.
		
		if [[ -z $(ps -ax $swd_survey_PID | tail +2) && $mini_window_launched == false ]]
		then
			launch_mini_window
			swd_echo "progresstext: Compressing logs and preparing to upload."
		fi
		
		sleep 1
		
	done

}

uploadSysdiagnose () {

	swd_echo "progress: 0"
	
	# Generate the AWS keys for the first file upload.
	generate_aws_keys "$sysDiagTarball" "itslog/logs/$serialNumber/$sysDiagTarball"

	# Upload. Supports anonymous upload if bucket is public-writable, and keys are set to ''.
	echo "Uploading: $srcfile to $bucket:$targfile"
	
	# Upload the file to the S3 bucket.
	# s3-accelerate is a high speed conduit via CloudFlare.
	# The 2>&1 and tr > log bits are used to get the percentage progress
	# which is then passed to swiftDialog.
	
	uploadStageDone=false
	uploadSuccess=false
	
	#--retry 3 --retry-delay 5	\
	#--limit-rate 5M			\
	
	curl -o /dev/null  			\
	-Y 0 -y 10					\
	-F "key=$targfile"			\
	-F "acl=$acl"				\
	$key_and_sig_args			\
	-F "Policy=$p"				\
	-F "Content-MD5=$md5"		\
	-F "Content-Type=$mime"		\
	-F "file=@$srcfile"			\
	"https://${bucket}.s3.amazonaws.com/" 2>&1 \
	| tr -u '\r' '\n' > /var/tmp/curlout.txt &
	curlPID=$(pgrep -P $$ curl)  
	echo "the PID of curl is $curlPID."
	
	sleep 1
	
}

awaitUserSurvey() {

	
	#while [[ -n $(ps -ax $swd_survey_PID | tail +2) || -n $(ps -ax $swd_mini_PID | tail +2) ]]
	until [[ $uploadStageDone == true && $surveyStageDone == true ]]
	do
		#echo "Survey is still open."
		
		# If user finishes the survey before curl or sysdiagnose are completed...
		# Launch the mini window to keep them informed.
		
		while [[ -n $(ps -ax "$curlPID" | tail +2) ]]
		do
			if [[ -z $(ps -ax $swd_survey_PID | tail +2) && $mini_window_launched == false ]]
			then
				launch_mini_window
				swd_echo "progresstext: Uploading logs:"
			fi
			
			sleep 1
			
			pctDone="$(tail -1 /var/tmp/curlout.txt | awk '{ print $1 }')"
			timeToFinish="$(tail -1 /var/tmp/curlout.txt | awk '{ print $11 }')"
			echo "Time to finish is $timeToFinish"
			
			if [[ $timeToFinish != "--:--:--" ]]
			then
				timeLeft="$(date -j -u -f "%Y-%m-%d %H:%M:%S" "1970-01-01 $timeToFinish" +%M:%S)"
			else
				timeLeft="00:00"
			fi
			
			swd_echo "progresstext: Uploading logs: $pctDone % - $timeLeft remaining"
			swd_echo "progress: $pctDone"
		done
		
		if [[ $uploadStageDone == false ]]
		then
			# Read the file one last time.
			pctDone="$(tail -1 /var/tmp/curlout.txt | awk '{ print $1 }')"
			sleep 1
			
			# if the upload falls short or the transfer dies unexpectedly, error out.
			# Otherwise, play some pretty sounds and celebrate!
			
			if [[ $pctDone =~ "curl" || ! $pctDone =~ ^[0-9]{1,3} || $pctDone -lt "100" ]]
			then
				swd_echo "message: An error occurred while uploading.  Please try again, or contact your administrator."
				swd_echo "progresstext: ❌ Upload failed.  Closing in 10 seconds..."
				/usr/bin/afplay -v 1.0 "/var/tmp/itslog-fail-sad-horns.m4a" &
				sleep 10
				uploadStageDone=true
				uploadSuccess=false
			else
				/usr/bin/afplay -v 1.0 "/var/tmp/itslog-success-xylophone.m4a" &
				if [[ $mini_window_launched == true ]]
				then
					swd_echo "message: ✅ File uploaded successfully!"
					swd_echo "progresstext: All done!  Closing in 10 seconds..."
                    sleep 10
                    swd_echo "quit:"
				else
					swd_echo "progresstext: ✅ File uploaded! Please complete the survey."
                    sleep 5
				fi
				timeStampEpoch=$(date -j +"%s")
				uploadSuccess=true
				uploadStageDone=true
			fi
		fi
				
		# If the user left the survey window open during the upload
		# This will check if they finally closed it out and help to exit the loop
		# So that their response can be uploaded to Amazon.
		
		if [[ -z $(ps -ax "$swd_survey_PID" | tail +2) && $uploadStageDone == true && $mini_window_launched == false ]]
		then
			surveyStageDone=true
		fi
		
		# However, if the user left the survey open for too long, we need to close it and move on.
		
		currentTimeEpoch="$(date -j +"%s")"
		surveyTimeLeft=$((secondsForSurvey - ((currentTimeEpoch - timeStampEpoch))))
		
		# echo "Survey time left: $surveyTimeLeft"
		
		if [[ $uploadStageDone == true && $surveyStageDone == false ]]
		then
			swd_echo "progresstext: ⏳ Time left to submit survey: $surveyTimeLeft"
		fi
		
		if [[ $surveyStageDone == false && $((currentTimeEpoch - timeStampEpoch)) -ge $secondsForSurvey ]]
		then
			echo -e "WARNING: User did not complete survey within the allotted time.  The survey was closed." \
			> "$surveyResponse"
			echo "WARNING: User did not complete survey within the allotted time."
			swd_echo "quit:"
			surveyStageDone=true
			surveyEmpty=true
		fi

		sleep 1
		
	done
	
}

uploadSurvey() {
	
	# Prepends the Survey response with some data about the computer
if [[ $surveyEmpty == false ]]
then
	echo -e "\
Log Filename   : $sysDiagTarball \n \
Serial Number  : $serialNumber \n \
Logged In User : $currentUser \n \
Mac Model ID   : $modelID \n \
MacOS Version  : $macOSvers ($macOSbuild) \n \
=================================== \n\n \
$(cat "$surveyResponse")" \
> "$surveyResponse"
fi	
	# Generate the keys for the survey responses and upload now.
	
	generate_aws_keys "${surveyResponse}" "itslog/surveys/$serialNumber/${surveyResponse}"
	
	curl -o /dev/null 			\
	-F "key=$targfile"			\
	-F "acl=$acl"				\
	$key_and_sig_args			\
	-F "Policy=$p"				\
	-F "Content-MD5=$md5"		\
	-F "Content-Type=$mime"		\
	-F "file=@$srcfile"			\
	"https://${bucket}.s3.amazonaws.com/" 2>&1 \
	| tr -u '\r' '\n' > /var/tmp/curlout-survey.txt
	
}

cleanUp() {
	
	echo "Cleaning up log and temporary files..."
	
	/bin/rm -rf "${sysDiagArchive}"
	/bin/rm -rf "${sysDiagTarball}"
	/bin/rm -rf "${surveyResponse}"
    swd_echo "quit:"
	
}


######## MAIN SEQUENCE

echo "Stage 0: initializing script parameters..."
initScriptParameters "$1" "$2" "$3" "$4" "$5" "$6"

######## An instance of swiftDialog is launched immediately

main() {
		
	echo "Stage 0: Launching survey window..."
	launchSurveyWindow 

	echo "Stage 1: Generating sysdiagnose logs (waits for completion)."
	generateSysdiagnose

	echo "Stage 2: Uploading sysdiagnose logs (backgrounded, returning control)"
	uploadSysdiagnose 
	
	echo "Stage 3: Waiting for user to complete survey..."
	awaitUserSurvey 
	
	echo "Stage 4: Survey stage has finished.  Uploading response..."
	uploadSurvey
	
	echo "Stage 5: Cleaning up temporary files..."
	cleanUp 

	echo "SCRIPT COMPLETE."
	
}

main

if [[ $uploadSuccess == false ]]
then
	echo "ERROR: ITS-LOG encountered a problem while uploading the file to Amazon.  Please check!"
	cleanUp
    exit 1
    
fi

exit 0



