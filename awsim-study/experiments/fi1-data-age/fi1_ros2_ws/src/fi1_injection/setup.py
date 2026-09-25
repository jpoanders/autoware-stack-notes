from setuptools import setup

package_name = 'fi1_injection'

setup(
    name=package_name,
    version='0.0.0',
    packages=[package_name],
    data_files=[
        ('share/ament_index/resource_index/packages',
            ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='janders',
    maintainer_email='jpoanders@gmail.com',
    description='FI1 Path A injector (stuck-sensor / data-age).',
    license='Apache-2.0',
    entry_points={
        'console_scripts': [
            'fi1_stuck_sensor = fi1_injection.fi1_stuck_sensor_node:main',
        ],
    },
)
