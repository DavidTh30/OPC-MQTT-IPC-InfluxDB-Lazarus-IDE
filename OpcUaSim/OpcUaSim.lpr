program OpcUaSim;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, umain, uaencode, uaserver, uplcsim;

{$R *.res}

begin
  MaskFPUExceptions;
  RequireDerivedFormResource := True;
  Application.Title := 'OPC UA Simulator';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
