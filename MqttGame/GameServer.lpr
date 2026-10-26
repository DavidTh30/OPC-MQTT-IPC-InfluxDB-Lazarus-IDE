program GameServer;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, ugameserver, mqttcodec, mqttbroker, snakeproto, snakegame, ugamehost;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Title := 'Snake Arena Server';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
