program IpcGameServer;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, ugameserver, uipchost, ipcshared, snakegame, snakeproto;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Title := 'Snake Arena Server (IPC)';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
