-- 아주르 프로밀리아 런처 (비공식)
-- 처음 실행하면 무료 Wine + DXMT, 넥슨 플러그, NGM을 준비하고, 그다음부터는 넥슨 플러그를 바로 켜요.
-- 실제 작업은 앱 안의 Contents/Resources/azurctl.sh가 해요.

property appTitle : "아주르 프로밀리아 런처"

on run
	set ctl to quoted form of (POSIX path of (path to me) & "Contents/Resources/azurctl.sh")
	set logDir to (POSIX path of (path to application support folder from user domain)) & "Azur Promilia Launcher/logs"
	do shell script "mkdir -p " & quoted form of logDir
	set setupLog to logDir & "/setup.log"

	set setupState to do shell script ctl & " status-code"
	if setupState is not "ready" then
		set msg to "처음 실행이라 준비가 필요해요. 몇 분 걸려요." & return & return & ¬
			"• 무료 Wine과 DXMT를 받아요 (이 맥에 Yaagl이 받아 둔 게 있으면 그걸 써요)" & return & ¬
			"• 넥슨 공식 서버에서 넥슨 플러그와 NGM을 받아요" & return & ¬
			"• CrossOver에 받아 둔 게임이 있으면 다시 받지 않고 가져와요" & return & return & ¬
			"비공식 런처예요. 넥슨은 맥을 지원하지 않고, 계정 제재 등의 위험은 본인 책임이에요."
		display dialog msg buttons {"취소", "준비 시작"} default button "준비 시작" cancel button "취소" with title appTitle with icon note

		set opts to do shell script ctl & " detect-sources"
		set progress total steps to -1
		set progress description to "준비하는 중이에요. 창을 닫지 마세요."
		set progress additional description to "진행 기록: " & setupLog
		try
			do shell script ctl & " setup " & opts & " > " & quoted form of setupLog & " 2>&1"
		on error
			display dialog "준비하다가 문제가 생겼어요." & return & return & "진행 기록: " & setupLog buttons {"기록 열기", "닫기"} default button "기록 열기" with title appTitle with icon stop
			if button returned of result is "기록 열기" then do shell script "open -e " & quoted form of setupLog
			return
		end try
	end if

	do shell script ctl & " plug"
end run
