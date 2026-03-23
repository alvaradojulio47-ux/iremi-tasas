@echo off
title IREMI Remesas - Proxy Binance
echo ============================================
echo   IREMI Remesas - Proxy Local
echo   Mantener esta ventana ABIERTA
echo ============================================
echo.

:: Check if Python is available
python --version 2>NUL
if errorlevel 1 (
    echo ERROR: Python no esta instalado
    echo Descarga Python desde https://python.org
    echo Asegurate de marcar "Add to PATH" al instalar
    pause
    exit /b 1
)

:: Install openpyxl if needed
echo Verificando dependencias...
python -c "import openpyxl" 2>NUL
if errorlevel 1 (
    echo Instalando openpyxl...
    pip install openpyxl
)

echo.
echo Iniciando proxy...
echo.

:: Run the proxy (stays open)
python iremi_proxy.py

:: If it exits (error or port in use), show the error and pause
echo.
echo ============================================
echo El proxy se detuvo. Revisa el error arriba.
echo ============================================
pause
