program IpcSnakeBGRA;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, usnakebgra, ipcsnakeclient, ipcshared, snakeproto;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Title := 'Snake Arena (BGRABitmap, IPC)';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
