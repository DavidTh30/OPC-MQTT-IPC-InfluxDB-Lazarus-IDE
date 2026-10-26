program IpcSnakeLCL;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, usnakelcl, ipcsnakeclient, ipcshared, snakeproto;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Title := 'Snake Arena (LCL, IPC)';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
