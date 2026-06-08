1 REM ================================================
2 REM  SIMPLE GAME STARTER - BASIC V2
3 REM  A starting point for your C64 BASIC game.
4 REM  Feel free to rename variables, add levels,
5 REM  or rework any section to fit your game idea!
6 REM ================================================

10 REM --- INITIALIZE ---
20 GOSUB 1000 : REM SETUP
30 GOSUB 2000 : REM TITLE SCREEN

40 REM --- MAIN GAME LOOP ---
50 GOSUB 3000 : REM READ JOYSTICK
60 GOSUB 4000 : REM UPDATE GAME
70 GOSUB 5000 : REM DRAW SCREEN
80 IF GA=0 THEN 50 : REM LOOP UNTIL GAME OVER
90 GOSUB 6000 : REM GAME OVER SCREEN
100 GOTO 30   : REM BACK TO TITLE

999 END

1000 REM ================================================
1001 REM  SETUP
1002 REM  Called once at startup. Initialize all your
1003 REM  game variables here before anything else runs.
1004 REM ================================================
1010 SC=0  : REM SCORE
1020 LV=3  : REM LIVES
1030 GA=0  : REM GAME OVER FLAG (0=PLAYING, 1=GAME OVER)
1040 PX=20 : REM PLAYER X POSITION (0-39)
1050 PY=12 : REM PLAYER Y POSITION (0-24)
1060 POKE 53280,0 : REM BORDER COLOR = BLACK
1070 POKE 53281,0 : REM BACKGROUND COLOR = BLACK
1080 RETURN

2000 REM ================================================
2001 REM  TITLE SCREEN
2002 REM  Show the game title and wait for fire button.
2003 REM  Joystick port 2 fire = bit 4 of $DC00 = 0 when pressed.
2004 REM ================================================
2010 PRINT CHR$(147) : REM CLEAR SCREEN
2020 PRINT : PRINT : PRINT
2030 PRINT "        *** MY AWESOME GAME ***"
2040 PRINT : PRINT
2050 PRINT "         PRESS FIRE TO START"
2060 REM WAIT FOR FIRE BUTTON ON PORT 2
2070 IF (PEEK(56320) AND 16) <> 0 THEN 2070
2080 REM WAIT FOR BUTTON RELEASE BEFORE CONTINUING
2090 IF (PEEK(56320) AND 16) = 0 THEN 2090
2100 RETURN

3000 REM ================================================
3001 REM  READ JOYSTICK
3002 REM  Reads joystick port 2 via $DC00 (56320).
3003 REM
3004 REM  WHY PORT 2?
3005 REM  Port 2 ($DC00) is read-only and safe to use
3006 REM  at any time. Port 1 ($DC01) shares lines with
3007 REM  the keyboard matrix, which can cause phantom
3008 REM  keypresses if both are read simultaneously.
3009 REM  Port 1 is fine if you need two players, but
3010 REM  be aware of the keyboard conflict.
3011 REM
3012 REM  TO SWITCH TO PORT 1: change PEEK(56320)
3013 REM  to PEEK(56321) throughout this routine.
3014 REM
3015 REM  BITS: 0=UP 1=DOWN 2=LEFT 3=RIGHT 4=FIRE
3016 REM  Bit = 0 means the direction is PRESSED.
3017 REM ================================================
3020 JY=PEEK(56320)
3030 JU=0 : JD=0 : JL=0 : JR=0 : JF=0
3040 IF (JY AND 1)  = 0 THEN JU=1 : REM UP
3050 IF (JY AND 2)  = 0 THEN JD=1 : REM DOWN
3060 IF (JY AND 4)  = 0 THEN JL=1 : REM LEFT
3070 IF (JY AND 8)  = 0 THEN JR=1 : REM RIGHT
3080 IF (JY AND 16) = 0 THEN JF=1 : REM FIRE
3090 RETURN

4000 REM ================================================
4001 REM  UPDATE GAME
4002 REM  Move the player, check collisions, update score.
4003 REM  JU/JD/JL/JR/JF are set by the joystick routine.
4004 REM ================================================
4010 REM MOVE PLAYER
4020 IF JU=1 AND PY>0  THEN PY=PY-1
4030 IF JD=1 AND PY<24 THEN PY=PY+1
4040 IF JL=1 AND PX>0  THEN PX=PX-1
4050 IF JR=1 AND PX<39 THEN PX=PX+1
4060 REM
4070 REM ADD YOUR GAME LOGIC HERE:
4080 REM   - Move enemies
4090 REM   - Check if player hit an enemy (GAME OVER)
4100 REM   - Check if player collected something (SCORE)
4110 REM   - Check if level is complete
4120 REM
4130 REM EXAMPLE: SET GAME OVER (remove this line when ready)
4140 REM GA=1
4150 RETURN

5000 REM ================================================
5001 REM  DRAW SCREEN
5002 REM  Update the display each frame.
5003 REM  Uses PRINT for simplicity. For faster drawing,
5004 REM  consider writing directly to screen RAM at $0400
5005 REM  using POKE. See your C64 memory map reference
5006 REM  for screen and color RAM addresses.
5007 REM ================================================
5010 REM DRAW SCORE AND LIVES AT TOP
5020 PRINT CHR$(19) : REM HOME CURSOR (no clear, less flicker)
5030 PRINT "SCORE:";SC;"   LIVES:";LV;"   "
5040 REM
5050 REM DRAW PLAYER CHARACTER AT PX,PY
5060 REM (Simple approach: position cursor, print a character)
5070 PRINT CHR$(19);       : REM HOME
5080 FOR I=1 TO PY : PRINT : NEXT I
5090 FOR I=1 TO PX : PRINT " "; : NEXT I
5100 PRINT CHR$(81);       : REM PRINT "@" (PETSCII BALL)
5110 REM
5120 REM ADD YOUR OWN DRAWING HERE
5130 RETURN

6000 REM ================================================
6001 REM  GAME OVER SCREEN
6002 REM  Show final score and wait for fire to continue.
6003 REM ================================================
6010 PRINT CHR$(147) : REM CLEAR SCREEN
6020 PRINT : PRINT : PRINT
6030 PRINT "           GAME OVER"
6040 PRINT : PRINT
6050 PRINT "        FINAL SCORE:"; SC
6060 PRINT : PRINT
6070 PRINT "         PRESS FIRE TO PLAY AGAIN"
6080 REM WAIT FOR FIRE
6090 IF (PEEK(56320) AND 16) <> 0 THEN 6090
6100 REM WAIT FOR RELEASE
6110 IF (PEEK(56320) AND 16) = 0 THEN 6110
6120 REM RESET GAME STATE FOR NEXT PLAY
6130 SC=0 : LV=3 : GA=0
6140 PX=20 : PY=12
6150 RETURN
